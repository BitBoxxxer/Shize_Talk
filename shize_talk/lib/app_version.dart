/// Версия приложения — простая константа вместо пакета package_info_plus
/// (он, как и video_editor раньше, почему-то не резолвился в этом проекте).
///
/// Держите это значение синхронным с `version:` в pubspec.yaml вручную —
const String appVersion = '0.2';
const String appBuildNumber = 'beta';
const String appVersionFull = '$appVersion+$appBuildNumber';
