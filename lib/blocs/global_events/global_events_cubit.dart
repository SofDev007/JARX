import 'dart:developer';

import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/services/app_updater.dart';
import 'package:Bloomee/services/bloomee_updater_tools.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:package_info_plus/package_info_plus.dart';

part 'global_events_state.dart';

class GlobalEventsCubit extends Cubit<GlobalEventsState> {
  final SettingsDAO _settingsDao;

  GlobalEventsCubit({required SettingsDAO settingsDao})
      : _settingsDao = settingsDao,
        super(GlobalEventsInitial()) {
    checkForUpdates();
  }

  void checkForUpdates() async {
    // Compulsory update: the last answer from GitHub is kept, so going
    // offline doesn't get around it; a fresh answer replaces it.
    // Saved as the release tag (`2.1.5+43`): rounds can share a build number.
    const requiredKey = 'updateRequiredBuild';
    final info = await PackageInfo.fromPlatform();
    final current = (int.tryParse(info.buildNumber) ?? 0) % 1000;
    void gate(String req) => UpdateGate.requiredBuild.value =
        isNewerTag(req, info.version, current) ? buildOfTag(req) : 0;
    gate(await _settingsDao.getSettingStr(requiredKey) ?? '');

    final Map<String, dynamic> updates = await getAppUpdates();
    log("Checking for updates...", name: 'GlobalEventsCubit');

    if (updates['source'] == 'github') {
      final req = updates['requiredTag'] as String? ?? '';
      await _settingsDao.putSettingStr(requiredKey, req);
      gate(req);
    }
    if (UpdateGate.blocked) {
      // The guided tour replaces the "Later / Update now" pop-up.
      UpdateGate.showTour();
      return;
    }

    if (updates['changelogs'] != null) {
      emit(WhatIsNewState(changeLogs: updates['changelogs']));
    }

    if (await _settingsDao.getSettingBool(SettingKeys.autoUpdateNotify) ??
        true) {
      // The pop-up shows once per new version; the Home bell keeps it.
      final tag = '${updates["newVer"]}+${updates["newBuild"]}';
      const shownKey = 'updatePopupShown';
      if (updates["results"] &&
          await _settingsDao.getSettingStr(shownKey) != tag) {
        await _settingsDao.putSettingStr(shownKey, tag);
        emit(UpdateAvailable(
          newVersion: updates["newVer"],
          newBuild: updates["newBuild"],
          downloadUrl: updates["download_url"] ?? '',
          notes: updates["notes"] ?? '',
        ));
      }
    }
  }

  void showAlertDialog(String title, String content) {
    emit(AlertDialogState(title: title, content: content));
  }
}
