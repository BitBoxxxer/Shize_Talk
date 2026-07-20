/// Форматирует дату как "10 мая 2026" — без пакета intl (чтобы не рисковать
/// ещё одной установкой пакета в этом проекте после истории с video_editor/
/// package_info_plus/ffmpeg-вариантами; простой словарь месяцев нам вполне
/// достаточен).
const _months = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];

String formatRuDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}
