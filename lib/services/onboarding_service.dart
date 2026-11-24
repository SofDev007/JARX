import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:package_info_plus/package_info_plus.dart';

class OnboardingService {
  static bool _onboardingDone = false;

  static bool get onboardingDone => _onboardingDone;

  static Future<void> checkAndCacheDone(SettingsDAO settingsDao) async {
    _onboardingDone =
        await settingsDao.getSettingBool(SettingKeys.appSetupCompleted) ??
            false;
    // Kept once: a fresh install (setup not done yet) is this version; a
    // phone that already had JARX installed it before this version.
    if (await settingsDao.getSettingStr(SettingKeys.firstVersion) == null) {
      final p = await PackageInfo.fromPlatform();
      final v = '${p.version}+${(int.tryParse(p.buildNumber) ?? 0) % 1000}';
      await settingsDao.putSettingStr(
          SettingKeys.firstVersion, _onboardingDone ? 'before $v' : v);
    }
  }

  static Future<void> markDone(SettingsDAO settingsDao) async {
    await settingsDao.putSettingBool(SettingKeys.appSetupCompleted, true);
    _onboardingDone = true;
  }
}
