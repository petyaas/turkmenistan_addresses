/// Diacritic folding. Must match FOLD in `tool/address_db_format.py`, or
/// typed text will never meet the names stored in the database.
///
/// Turkmen names use ä, ç, ň, ö, ş, ü, ý and nobody is going to type them
/// on a keyboard — `gorogly` has to find `Görogly köçesi`.
const Map<String, String> _fold = {
  'ä': 'a', 'ç': 'c', 'ž': 'z', 'ň': 'n', 'ö': 'o',
  'ş': 's', 'ü': 'u', 'ý': 'y', 'é': 'e', 'ı': 'i',
  'İ': 'i', 'ğ': 'g', 'ё': 'е',
};

/// Punctuation that survives folding: the slash and the hyphen are part of
/// house numbers ("2/4", "12-а"). Matches KEPT_PUNCTUATION in
/// `tool/address_db_format.py`.
const String keptPunctuation = '/-';

/// Reduces text to the form comparisons run on.
///
/// Lower case, folded diacritics, punctuation turned into spaces:
/// demanding the comma in "Parahat 2/4, 1" is no good when people type
/// from memory, on the move.
String normalize(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final character = String.fromCharCode(rune);
    final folded = _fold[character] ?? character;
    buffer.write(_isKept(folded) ? folded : ' ');
  }
  return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool _isKept(String character) {
  if (keptPunctuation.contains(character)) return true;
  final code = character.codeUnitAt(0);
  // Digits, Latin letters, and everything above ASCII: Cyrillic and the
  // Turkmen letters.
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x61 && code <= 0x7A) ||
      code > 0x7F;
}

/// Where [token] sits in the key if it starts some word there, else -1.
///
/// Matching from mid-word is rejected on purpose: "rahat" must not find
/// "Parahat", or the results fill up with accidental hits.
///
/// This uses indexOf rather than splitting the key into words: splitting
/// thirteen thousand keys on every keystroke would cost more than the
/// search itself.
int wordPrefixAt(String key, String token) {
  var at = key.indexOf(token);
  while (at >= 0) {
    if (at == 0 || key.codeUnitAt(at - 1) == 0x20) return at;
    at = key.indexOf(token, at + 1);
  }
  return -1;
}

/// Splits a query into words, longest first: those rule out most entries
/// on the very first check.
List<String> tokenize(String needle) {
  final tokens = needle.split(' ')..removeWhere((token) => token.isEmpty);
  tokens.sort((a, b) => b.length.compareTo(a.length));
  return tokens;
}
