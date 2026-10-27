const _accented = 'áàâãäåéèêëíìîïóòôõöúùûüçñ';
const _plain = 'aaaaaaeeeeiiiiooooouuuucn';

String normalizeSearchName(String value) {
  final lower = value.toLowerCase().trim();
  // Most file names are ASCII; skip the per-character mapping for them.
  var ascii = true;
  for (var i = 0; i < lower.length; i++) {
    if (lower.codeUnitAt(i) > 127) {
      ascii = false;
      break;
    }
  }
  if (ascii) return lower;
  return String.fromCharCodes(
    lower.runes.map((rune) {
      final index = _accented.indexOf(String.fromCharCode(rune));
      return index < 0 ? rune : _plain.codeUnitAt(index);
    }),
  );
}
