/// Свёртка диакритики. Обязана совпадать с FOLD в
/// `tool/address_db_format.py`, иначе набранный текст не сойдётся с
/// названиями из базы.
///
/// Туркменские названия пишутся через ä, ç, ň, ö, ş, ü, ý, а набирать их
/// на клавиатуре никто не станет — «gorogly» обязан находить
/// «Görogly köçesi».
const Map<String, String> _fold = {
  'ä': 'a', 'ç': 'c', 'ž': 'z', 'ň': 'n', 'ö': 'o',
  'ş': 's', 'ü': 'u', 'ý': 'y', 'é': 'e', 'ı': 'i',
  'İ': 'i', 'ğ': 'g', 'ё': 'е',
};

/// Знаки, остающиеся в ключе: дробь и дефис — часть номера дома («2/4»,
/// «12-а»). Совпадает с KEPT_PUNCTUATION в `tool/address_db_format.py`.
const String keptPunctuation = '/-';

/// Приводит текст к виду, в котором идёт сравнение.
///
/// Строчные буквы, свёрнутая диакритика, знаки препинания вместо пробелов:
/// требовать от человека запятую в «Parahat 2/4, 1» нельзя, набирают на
/// ходу и по памяти.
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
  // Цифры, латиница и всё, что выше ASCII: кириллица и туркменские буквы.
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x61 && code <= 0x7A) ||
      code > 0x7F;
}

/// Позиция слова [token] в ключе, если оно стоит в начале какого-нибудь
/// слова. Иначе -1.
///
/// Совпадение с середины слова не принимается намеренно: «rahat» не
/// должно находить «Parahat», иначе выдача заполняется случайными
/// попаданиями.
///
/// Ищем через indexOf, а не разбивая ключ на слова: разбиение тринадцати
/// тысяч ключей на каждое нажатие клавиши стоило бы дороже самого поиска.
int wordPrefixAt(String key, String token) {
  var at = key.indexOf(token);
  while (at >= 0) {
    if (at == 0 || key.codeUnitAt(at - 1) == 0x20) return at;
    at = key.indexOf(token, at + 1);
  }
  return -1;
}

/// Разбивает запрос на слова, длинные вперёд: они отсекают большинство
/// записей с первой же проверки.
List<String> tokenize(String needle) {
  final tokens = needle.split(' ')..removeWhere((token) => token.isEmpty);
  tokens.sort((a, b) => b.length.compareTo(a.length));
  return tokens;
}
