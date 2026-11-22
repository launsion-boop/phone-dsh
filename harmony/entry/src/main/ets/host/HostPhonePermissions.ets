// SPDX-License-Identifier: MIT
// The phone-permissions matrix's host half: real HarmonyOS reads in, page
// rows out. One row per capability, in the Android matrix's declaration order
// (android/lib/src/main/kotlin/com/phonedsh/ui/page/PhonePermissionsPage.kt),
// and one rule: a status is reported only when this device actually reports it.
//
// Reads used here, all public SDK APIs:
//   * bundleManager.getBundleInfoForSelf(GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION |
//     GET_BUNDLE_INFO_WITH_APPLICATION) for the merged manifest's declared
//     permissions (reqPermissionDetails) and the app's accessTokenId
//     (appInfo.accessTokenId);
//   * abilityAccessCtrl.AtManager.checkAccessTokenSync(accessTokenId, permission)
//     for the platform's actual grant state of each *declared* permission;
//   * notificationManager.isNotificationEnabled() for this app's own
//     notification switch (no permission dialog is raised);
//   * deviceInfo.productModel / brand / sdkApiVersion for the device row.
//
// What this file deliberately does not do:
//   * no permission request, no system dialog, no manifest change;
//   * a permission the manifest does not declare has no platform grant state,
//     so its row is 未知 with the reason, never 已拒绝 or "hardware unavailable";
//   * a user_grant permission the manifest declares but the platform answers
//     DENIED is reported as 未授予, not 已拒绝: this host never sends a request,
//     so it cannot tell "never asked" from "asked and refused";
//   * PhotoPicker's scoped-URI grants are not a full photo-library grant, so
//     the photos row never borrows them as 已允许;
//   * capabilities this host has no audit for produce no audit records.

import { abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import deviceInfo from '@ohos.deviceInfo';
import { NamedItem } from '../model/Contracts';
import { LocaleText } from '../model/LocaleText';

const STATE_GRANTED: string = '已允许';
const STATE_NOT_GRANTED: string = '未授予';
const STATE_UNKNOWN: string = '未知';
const STATE_ALWAYS_ON: string = '常开';
const STATE_NOTIFICATION_ON: string = '已开启';
const STATE_NOTIFICATION_OFF: string = '已关闭';
const GROUP_PREFIX: string = 'permission-group:';
const ITEM_PREFIX: string = 'permission:';

/**
 * One row of the 22-capability matrix: the page's id/title/purpose/group plus
 * the HarmonyOS permission names that can answer it (empty when no permission
 * gates the capability).
 */
class PermissionSpec {
  readonly id: string;
  readonly title: string;
  readonly purpose: string;
  readonly group: string;
  readonly permissions: string[];

  constructor(id: string, title: string, purpose: string, group: string, permissions: string[]) {
    this.id = id;
    this.title = title;
    this.purpose = purpose;
    this.group = group;
    this.permissions = permissions;
  }
}

/** The outcome of one permission-backed row's read. */
class PermissionReading {
  readonly state: string;
  readonly reason: string;

  constructor(state: string, reason: string) {
    this.state = state;
    this.reason = reason;
  }
}

export class HostPhonePermissions {
  private static readonly GROUPS: string[] = [
    '个人信息', '设备与传感器', '系统与通知', '文件与数据', '家庭与媒体'
  ];

  // Titles and purposes are the Android matrix's; the permission names are the
  // HarmonyOS equivalents, used only to look the declared permission up.
  private static readonly MATRIX: PermissionSpec[] = [
    new PermissionSpec(
      'contacts', '通讯录', '仅在你查询时读取联系人；电话和邮箱默认脱敏。', '个人信息',
      ['ohos.permission.READ_CONTACTS']
    ),
    new PermissionSpec(
      'calendar', '日历', '读取你选择时间范围内的日程，并在确认后创建日程。', '个人信息',
      ['ohos.permission.READ_CALENDAR']
    ),
    new PermissionSpec(
      'reminders', '提醒事项', '读取提醒事项，并在确认后创建或完成提醒。', '个人信息', []
    ),
    new PermissionSpec(
      'health',
      '健康',
      '将读取：步数、睡眠、心率、静息心率、HRV、训练、体重、正念；不写入健康数据。',
      '个人信息',
      []
    ),
    new PermissionSpec(
      'photos', '照片', '读取照片元数据，用于查找最近或指定日期的照片。', '个人信息',
      ['ohos.permission.READ_IMAGEVIDEO']
    ),
    new PermissionSpec(
      'camera', '相机', '仅在你发起拍摄时采集照片或扫描文稿。', '设备与传感器',
      ['ohos.permission.CAMERA']
    ),
    new PermissionSpec(
      'microphone', '麦克风', '仅在你发起录音时采集音频。', '设备与传感器',
      ['ohos.permission.MICROPHONE']
    ),
    new PermissionSpec(
      'speech', '语音识别', '将你选择的录音转换为文字。', '设备与传感器',
      ['ohos.permission.MICROPHONE']
    ),
    new PermissionSpec(
      'location', '定位', '仅在你查询时获取一次当前位置。', '设备与传感器',
      ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION']
    ),
    new PermissionSpec(
      'motion', '运动与健身', '读取你指定时间内的活动与步数。', '设备与传感器',
      ['ohos.permission.ACTIVITY_MOTION']
    ),
    new PermissionSpec(
      'bluetooth', '蓝牙', '仅在你发起扫描时发现附近蓝牙设备。', '设备与传感器',
      ['ohos.permission.ACCESS_BLUETOOTH']
    ),
    new PermissionSpec(
      'localNetwork', '本地网络', '点击后通过系统网络浏览器实测局域网发现能力。', '设备与传感器',
      ['ohos.permission.INTERNET']
    ),
    new PermissionSpec(
      'notifications', '通知', '仅在你确认后发送本地通知，不接收远程推送。', '系统与通知', []
    ),
    new PermissionSpec(
      'biometrics', '面容确认',
      '启用后，敏感写操作前需要系统生物识别确认；这不是单独系统授权。',
      '系统与通知', []
    ),
    new PermissionSpec(
      'focus', '专注模式', '读取系统当前是否处于专注（勿扰）状态。', '系统与通知', []
    ),
    new PermissionSpec(
      'liveActivity', '实时活动', '通过系统的实时活动机制创建和更新进行中的活动。',
      '系统与通知', []
    ),
    new PermissionSpec(
      'shortcuts', '快捷指令', '打开指定的快捷指令；跨 App 执行结果无法观测，不承诺已完成。',
      '系统与通知', []
    ),
    new PermissionSpec(
      'filesFolder', '文件与文件夹', '通过系统选择器授权你选择的文件夹，不读取其它 App 容器。',
      '文件与数据', []
    ),
    new PermissionSpec(
      'clipboard', '剪贴板', '仅在你明确调用时读取或写入系统剪贴板。', '文件与数据', []
    ),
    new PermissionSpec(
      'device', '设备状态', '只读显示设备型号、系统版本和当前时间，始终启用。',
      '文件与数据', []
    ),
    new PermissionSpec(
      'homekit', '家庭', '读取你授权的家庭与配件，并在确认后写入指定特征。',
      '家庭与媒体', []
    ),
    new PermissionSpec(
      'music', '音乐', '通过系统音乐目录播放你指定的真实曲目。', '家庭与媒体', []
    ),
  ];

  /**
   * Read the matrix from the real platform. Throws only when the bundle/access
   * token read itself fails; a per-row read failure becomes that row's 未知.
   */
  static async read(language: string): Promise<NamedItem[]> {
    const flags: number = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION |
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
    const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(flags);
    const tokenId: number = info.appInfo.accessTokenId;
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const declared: string[] = [];
    const details: bundleManager.ReqPermissionDetail[] = info.reqPermissionDetails;
    if (details !== undefined && details !== null) {
      for (let index = 0; index < details.length; index++) {
        const name: string = details[index].name;
        if (name !== undefined && name !== null && name.length > 0) {
          declared.push(name);
        }
      }
    }

    const items: NamedItem[] = [];
    let currentGroup: string = '';
    for (let index = 0; index < HostPhonePermissions.MATRIX.length; index++) {
      const spec: PermissionSpec = HostPhonePermissions.MATRIX[index];
      if (spec.group !== currentGroup) {
        currentGroup = spec.group;
        const header = new NamedItem();
        header.id = `${GROUP_PREFIX}${currentGroup}`;
        header.title = LocaleText.tr(language, currentGroup);
        header.subtitle = '';
        header.detail = '';
        header.enabled = false;
        items.push(header);
      }
      items.push(await HostPhonePermissions.row(spec, declared, tokenId, atManager, language));
    }
    return items;
  }

  private static async row(
    spec: PermissionSpec,
    declared: string[],
    tokenId: number,
    atManager: abilityAccessCtrl.AtManager,
    language: string
  ): Promise<NamedItem> {
    const item = new NamedItem();
    item.id = `${ITEM_PREFIX}${spec.id}`;
    item.title = LocaleText.tr(language, spec.title);
    item.enabled = false;
    let state: string = STATE_UNKNOWN;
    let reason: string = '';
    if (spec.id === 'device') {
      state = STATE_ALWAYS_ON;
      reason = LocaleText.fill(language, '只读设备信息：{0} · {1} · API {2}', [
        deviceInfo.productModel, deviceInfo.brand, deviceInfo.sdkApiVersion.toString()
      ]);
    } else if (spec.id === 'notifications') {
      try {
        const enabled: boolean = await notificationManager.isNotificationEnabled();
        state = enabled ? STATE_NOTIFICATION_ON : STATE_NOTIFICATION_OFF;
        reason = LocaleText.tr(language, '读取本应用的通知开关（isNotificationEnabled）；通知不通过运行时权限授予，本页不弹系统对话框。');
      } catch (error) {
        state = STATE_UNKNOWN;
        reason = LocaleText.fill(language, '读取应用通知开关失败：{0}', [
          HostPhonePermissions.errorText(error, language)
        ]);
      }
    } else if (spec.permissions.length === 0) {
      state = STATE_UNKNOWN;
      reason = HostPhonePermissions.noReadingReason(spec.id, language);
    } else {
      const reading: PermissionReading =
        HostPhonePermissions.readDeclared(spec, declared, tokenId, atManager, language);
      state = reading.state;
      reason = reading.reason;
    }
    item.subtitle = LocaleText.tr(language, state);
    item.detail = `${LocaleText.tr(language, spec.purpose)}｜${reason}`;
    return item;
  }

  /**
   * A permission-backed row: only a permission this manifest actually declares
   * can have an OS grant state. A DENIED answer becomes 未授予, because this
   * host never requests permissions and therefore has no ask log to separate
   * "never asked" from "asked and refused".
   */
  private static readDeclared(
    spec: PermissionSpec,
    declared: string[],
    tokenId: number,
    atManager: abilityAccessCtrl.AtManager,
    language: string
  ): PermissionReading {
    const present: string[] = [];
    for (let index = 0; index < spec.permissions.length; index++) {
      if (HostPhonePermissions.contains(declared, spec.permissions[index])) {
        present.push(spec.permissions[index]);
      }
    }
    if (present.length === 0) {
      const pickerNote: string = spec.id === 'photos'
        ? LocaleText.tr(language, ' PhotoPicker 按 URI 授权，不等同整库照片权限，不能当作已允许。')
        : '';
      return new PermissionReading(
        STATE_UNKNOWN,
        LocaleText.fill(language, '未在 module.json5 声明 {0}；平台不报告未声明权限的授权状态。{1}', [
          spec.permissions.join(' / '), pickerNote
        ])
      );
    }
    let granted: boolean = false;
    let readError: string = '';
    for (let index = 0; index < present.length; index++) {
      try {
        const status: abilityAccessCtrl.GrantStatus = atManager.checkAccessTokenSync(
          tokenId, present[index] as Permissions
        );
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          granted = true;
        }
      } catch (error) {
        readError = HostPhonePermissions.errorText(error, language);
      }
    }
    if (granted) {
      const note: string = spec.id === 'localNetwork'
        ? LocaleText.tr(language, 'INTERNET 为 normal 权限，实际授权已读；网络访问权限不代表局域网发现已验证。')
        : LocaleText.tr(language, '平台授权状态由 checkAccessTokenSync 读取。');
      return new PermissionReading(STATE_GRANTED, note);
    }
    if (readError.length > 0) {
      return new PermissionReading(STATE_UNKNOWN,
        LocaleText.fill(language, '读取授权状态失败：{0}', [readError]));
    }
    return new PermissionReading(
      STATE_NOT_GRANTED,
      LocaleText.tr(language, '清单已声明，平台返回未授予；本宿主未发起权限请求，无法区分未请求与已拒绝。')
    );
  }

  /** Why a row with no permission name stays 未知: platform absence, not a guess. */
  private static noReadingReason(id: string, language: string): string {
    if (id === 'reminders') {
      return LocaleText.tr(language, 'HarmonyOS 无系统提醒事项授权；本宿主未接入该能力。');
    }
    if (id === 'health') {
      return LocaleText.tr(language, '宿主未声明健康数据权限，也未接入健康数据读取。');
    }
    if (id === 'biometrics') {
      return LocaleText.tr(language, '本宿主未接入生物识别调用；没有可读的独立系统授权项。');
    }
    if (id === 'focus') {
      return LocaleText.tr(language, '本宿主未接入系统勿扰状态读取。');
    }
    if (id === 'liveActivity') {
      return LocaleText.tr(language, '本宿主未接入实时活动。');
    }
    if (id === 'shortcuts') {
      return LocaleText.tr(language, 'HarmonyOS 无系统快捷指令授权；本宿主未接入。');
    }
    if (id === 'filesFolder') {
      return LocaleText.tr(language, '系统 Picker 按 URI 授权，不等同于整目录持久授权。');
    }
    if (id === 'clipboard') {
      return LocaleText.tr(language, '剪贴板 API 无系统授权项；本宿主未接入。');
    }
    if (id === 'homekit') {
      return LocaleText.tr(language, 'HarmonyOS 无家庭框架授权；本宿主未接入。');
    }
    if (id === 'music') {
      return LocaleText.tr(language, '宿主未接入系统媒体目录；没有可读的音乐授权。');
    }
    return LocaleText.tr(language, '本宿主没有可读取的授权状态。');
  }

  private static contains(values: string[], target: string): boolean {
    for (let index = 0; index < values.length; index++) {
      if (values[index] === target) {
        return true;
      }
    }
    return false;
  }

  private static errorText(error: Object, language: string): string {
    const typed: Error = error as Error;
    if (typed !== undefined && typed !== null && typed.message !== undefined &&
      typed.message.length > 0) {
      return typed.message;
    }
    return LocaleText.tr(language, '未知错误');
  }
}
