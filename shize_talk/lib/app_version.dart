/// Версия приложения — простая константа вместо пакета package_info_plus
/// (он, как и video_editor раньше, почему-то не резолвился в этом проекте).
///
/// Держите это значение синхронным с `version:` в pubspec.yaml вручную —
/// когда там меняете `1.0.0+1` на `1.1.0+2`, поменяйте и здесь.
const String appVersion = '1.0.0';
const String appBuildNumber = '1';
const String appVersionFull = '$appVersion+$appBuildNumber';
