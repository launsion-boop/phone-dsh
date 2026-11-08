import { ImageLoadControl } from '../model/ImageLoadControl';
// SPDX-License-Identifier: MIT
// The ArkTS host service: one native HostSnapshot, one hidden ArkWeb Worker, and
// every ShellAction. Native owns /dsh, the WAL and the ordered channel. This
// class owns only the UI projection, its private preferences/session file, the
// AssetStore key, and the NetworkKit model edge.
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { detachedSettings, publishSnapshot } from '../model/SnapshotProjection';
import i18n from '@ohos.i18n';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import native from 'libpdshhost.so';
import {
  ChatRow,
  EnginePhase,
  FileEntry,
  FontRole,
  ImageBytes,
  LoadPhase,
  NamedItem,
  Page,
  PendingRequest,
  ProviderConfig,
  ProviderProfileRecord,
  RowKind,
  SessionArtifact,
  SessionRecord,
  Settings,
  ShellActions,
  ShellSnapshot,
  Workspace
} from '../model/Contracts';
import {
  QueueItem,
  QueueItemAction,
  QueueItemState,
  QueueOrigin,
  QueueProjectionResult,
  acknowledgeLocalQueuePrompt,
  admittedUserPromptRequestId,
  containsPromptRequestId,
  durableQueueItemById,
  encodeQueueUpdate,
  failLocalQueuePrompt,
  localQueueEcho,
  mergeDurableQueue,
  parseQueueProjection,
  queueActionConfirmed,
  retireLocalQueueByDurable,
  retireLocalQueuePrompt,
  retireOwnedQueueRequest
} from '../model/QueueModel';
import { LocaleText } from '../model/LocaleText';
import {
  ComposerReferenceSessionFact,
  REFERENCE_DIRECTORY_LIMIT,
  REFERENCE_FILE_LIMIT,
  referenceRelativePath,
  referenceSessionTitles
} from '../model/ComposerReferences';
import {
  parseSessionMetrics,
  turnOutcomeOf,
  TurnOutcome
} from '../model/ChatMetrics';
import {
  QuestionOutcome,
  buildQuestionOutcome,
  parseQuestionItems
} from '../model/QuestionAnswers';
import {
  LegacyProvider,
  PROVIDER_LAUNCH_FILE,
  ProviderProfilesState,
  cloneProviderProfile,
  cloneProviderProfiles,
  findProviderProfile,
  migrateProviderProfiles,
  providerCredentialAlias,
  providerKeyRejection,
  providerLaunchDocument,
  providerLaunchSelectedModel,
  providerProfileRejection,
  selectedProviderProfile,
  withDeletedProviderProfile,
  withSelectedProviderProfile,
  withUpsertedProviderProfile
} from '../model/ProviderProfiles';
import {
  NavigationFrame,
  navCanGoBack,
  navCurrentFrame,
  navFilesFrame,
  navPopFrame,
  navPreviewFrame,
  navPushFrame,
  navReset
} from '../model/Navigation';
import {
  SessionModelSelection,
  SessionPermissionOption,
  modelOptionsFromCatalog,
  permissionFromProjections,
  permissionOptionsFromCatalog,
  resolveModelSelection,
  selectionFromProjections
} from '../model/SessionControls';
import {
  ComposerCommandExecution,
  commandsFromCatalog,
  isRegisteredSlashCommand,
  parseCommandExecution
} from '../model/ComposerInput';
import { PageBridge, PageBridgeListener } from './HostBridge';
import {
  MAX_REMOTE_IMAGE_BYTES,
  MAX_REMOTE_REDIRECTS,
  ResourceContext,
  ResourceKind,
  concatBytes,
  decodeBase64,
  exactArrayBuffer,
  isImagePath,
  isValidRemoteUri,
  mimeForPath,
  nextRemoteRedirect,
  refusalText,
  resolveMarkdownResource
} from '../model/ResourceLocator';
import {
  HostHttpProxy,
  ModelRouteConfig,
  ProviderProbeResult,
  ProxyResponder
} from './HostHttpProxy';
import { officialWebModelBaseEligible } from './HostModelAlias';
import { DraftRecord, HostPersistence, StoredChatDocument } from './HostPersistence';
import { HostPhonePermissions } from './HostPhonePermissions';
import { HostSecure, KeyReadResult, KeyWriteResult } from './HostSecure';
import {
  FollowSnapshotProjection,
  TranscriptMergeResult,
  TranscriptRow,
  mergeTranscriptRows,
  projectEvent,
  projectFollowSnapshot,
  turnEndDetailOf
} from './TranscriptProjection';
import {
  CloseStreamArgs,
  EventAnswerArgs,
  EventsArgs,
  FollowArgs,
  PluginToggleArgs,
  PromptContent,
  SessionCancelArgs,
  SessionCancelRequest,
  SessionCreateArgs,
  SessionCreateRequest,
  SessionPromptArgs,
  SessionPromptRequest,
  SettingsUpdateArgs,
  WriteFileArgs,
  asArray,
  asRecord,
  baseName,
  bounded,
  decodeUtf8,
  delay,
  encodeBase64,
  encodeUtf8,
  errorText,
  jsonBool,
  jsonNumber,
  jsonString,
  parseJsonObject,
  promptContent,
  redact,
  toArrayBuffer,
  uniqueId
} from './HostUtil';

/** One bundled notice entry on the Licenses page; files are rawfile paths. */
class LicenseSource {
  id: string = '';
  title: string = '';
  subtitle: string = '';
  files: string[] = [];
}

class NativeRuntimeInfo {
  port: number = 0;
  token: string = '';
  bootId: string = '';
  sessionEpoch: number = 0;
  ackedMseq: number = 0;
  recoveredBytes: number = 0;
  error: string = '';
}

class ItemMeta {
  kind: string = '';
  ns: string = '';
  field: string = '';
  valueType: string = 'string';
  revision: number = 0;
  sessionId: string = '';
  title: string = '';
  options: string[] = [];
}

class PendingMeta {
  id: string = '';
  clientId: string = '';
  eventKind: string = '';
  body: Record<string, Object> | null = null;
  title: string = '';
}

class ConfigSpec {
  ns: string = '';
  field: string = '';
  type: string = '';

  constructor(ns: string, field: string, type: string) {
    this.ns = ns;
    this.field = field;
    this.type = type;
  }
}

/** One schedule record exactly as `schedule/catalog` reported it. */
class AutomationSchedule {
  id: string = '';
  title: string = '';
  prompt: string = '';
  kind: string = '';
  status: string = '';
  scheduledAt: string = '';
  afterSeconds: string = '';
  everySeconds: string = '';
  time: string = '';
  timeZone: string = '';
  expression: string = '';
  weekdays: string = '';
  detail: string = '';
  updatedAt: string | null = null;
}

class EmptyArgs {
}

class RequestWrapper {
  request: Record<string, Object> = {};

  constructor(request: Record<string, Object>) {
    this.request = request;
  }
}

/**
 * The durable-write result. Empty `error` is the only success value, mirroring
 * Android `ChatWriteOutcome.Persisted`; a failed save can never be reported as
 * "saved" just because the in-memory mutation happened.
 */
class PersistOutcome {
  ok: boolean = true;
  error: string = '';

  constructor(error?: string) {
    if (error !== undefined && error.length > 0) {
      this.ok = false;
      this.error = error;
    }
  }
}

const EMPTY_ARGS: EmptyArgs = new EmptyArgs();

interface PermissionOutcome {
  kind: string;
  value: string;
}

const CONFIG_SPECS: ConfigSpec[] = [
  new ConfigSpec('agent-loop', 'maxParallelToolCalls', 'number'),
  new ConfigSpec('subagent', 'maxDepth', 'number'),
  new ConfigSpec('subagent', 'maxActiveSubagents', 'number'),
  new ConfigSpec('subagent-model-selection-settings', 'enabled', 'boolean'),
  new ConfigSpec('subagent-model-selection-settings', 'allowedModels', 'modelSelection'),
  new ConfigSpec('bash-sandbox', 'timeoutMs', 'number'),
  new ConfigSpec('bash-sandbox', 'maxOutputBytes', 'number')
];

const CONTEXT_LOST: string =
  '上一段上下文已丢失：之前的 Worker 会话已无法恢复（session/not-found），这条消息开了一个新会话，模型看不到更早的内容。';

export class HostService implements ShellActions, PageBridgeListener, ProxyResponder {
  snapshot: ShellSnapshot = new ShellSnapshot();
  onChange: ((snapshot: ShellSnapshot) => void) | undefined = undefined;
  bridge: PageBridge;

  private pageBridge: PageBridge;
  private proxy: HostHttpProxy = new HostHttpProxy();
  private secure: HostSecure = new HostSecure();
  private persistence: HostPersistence | null = null;
  private context: common.UIAbilityContext | null = null;
  // The profile, endpoint, model and key alias this process booted with. Saving
  // or selecting another profile never reroutes the running Worker; the next
  // native start re-freezes this from the then-selected record.
  private bootProvider: ProviderProfileRecord | null = null;
  // Frozen at boot: eligible official DeepSeek base plus a live, readable
  // model key. It gates both the launch flag and the proxy's tool routes; a
  // stale UI key fact never decides it.
  private officialWebTools: boolean = false;
  private initialized: boolean = false;
  private initPromise: Promise<void> | null = null;
  private nativeRunning: boolean = false;
  private workerReady: boolean = false;
  private runtimeToken: string = '';
  private runtimeStartPromise: Promise<void> | null = null;
  private disposed: boolean = false;

  private activeStreamId: string = '';
  private activeStreamSessionId: string = '';
  private streamClosedByUs: boolean = false;
  private pendingTurns: number = 0;
  // The private turn group still owns artifact ranges, but it no longer drives
  // any visible queue count. These ids are only our own still-pending queued
  // prompts; a durable remove may retire exactly one of them.
  private pendingOwnQueueRequestIds: string[] = [];
  // Bumped on session/runtime switch. Every async queue response must still
  // match this generation and the active Worker session before it lands.
  private queueGeneration: number = 0;
  private queueRefreshInFlight: boolean = false;
  private queueRefreshQueued: boolean = false;
  // One measured mseq range per session turn group. The watermark is the cached
  // native ACK, read without the Store lock; see beginArtifacts/endArtifacts.
  private artifactsOpen: boolean = false;
  private artifactsSessionId: string = '';
  private artifactsFromMseq: string = '';
  private eventsReady: boolean = false;
  private eventsClientId: string = '';
  private eventsWaiter: (() => void) | null = null;
  private followWaiters: Map<string, () => void> = new Map();
  private followSeen: Set<string> = new Set();
  private pendingMeta: Map<string, PendingMeta> = new Map();
  private answeringRequests: Map<string, boolean> = new Map();
  private itemMeta: Map<string, ItemMeta> = new Map();
  private automationRecords: Map<string, AutomationSchedule> = new Map();
  private modelChoices: string[] = [];
  private drafts: Map<string, string> = new Map();
  private saveTimer: number = -1;
  private stopTimer: number = -1;
  private streamEmitTimer: number = -1;
  private loadGeneration: number = 0;
  private lastPersistError: string = '';
  private controlsGeneration: number = 0;
  private projectionFailure: string = '';
  // The open turn's Worker facts. `0` means the event did not carry a usable
  // clock, which keeps the page from substituting a client Date.now().
  private activeTurnId: string = '';
  private activeTurnStartedAt: number = 0;
  private valueStack: NavigationFrame[] = navReset();

  constructor() {
    this.pageBridge = new PageBridge(this);
    this.bridge = this.pageBridge;
    this.proxy.setResponder(this);
  }

  // ------------------------------------------------------------- lifecycle

  async initialize(ctx: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.initPromise = this.doInitialize(ctx);
    return this.initPromise;
  }

  attach(controller: webview.WebviewController): void {
    this.pageBridge.attach(controller);
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    if (this.streamEmitTimer >= 0) {
      clearTimeout(this.streamEmitTimer);
      this.streamEmitTimer = -1;
    }
    this.persistNow();
    this.closeAllStreams();
    this.proxy.cancelPending();
    this.proxy.dispose();
    this.pageBridge.dispose();
    if (this.nativeRunning) {
      try {
        native.stop();
      } catch (error) {
      }
      this.nativeRunning = false;
    }
    this.workerReady = false;
    this.runtimeToken = '';
  }

  pageLoaded(): void {
    if (this.snapshot.engine === EnginePhase.Booting || this.snapshot.engine === EnginePhase.Recovering) {
      this.snapshot.engineText = this.uiCopy('本地页面已加载，正在等待 Worker 就绪');
      this.emit();
    }
  }

  pageFailed(reason: string): void {
    const message = this.clean(reason);
    this.proxy.cancelPending();
    this.workerReady = false;
    this.resetSessionControls();
    this.snapshot.engine = EnginePhase.Failed;
    this.snapshot.engineText = this.uiCopy('本地运行时页面失败');
    this.snapshot.failure = message;
    this.snapshot.running = false;
    this.pendingTurns = 0;
    this.clearQueueState();
    this.emit();
  }

  onBridgeReady(): void {
    this.workerReady = true;
    this.snapshot.engine = EnginePhase.Ready;
    this.snapshot.engineText = this.uiCopy('本地运行时已就绪');
    this.snapshot.failure = '';
    this.configureProxyRoute();
    this.emit();
    this.refreshControlsQuietly();
  }

  onBridgeError(message: string): void {
    this.proxy.cancelPending();
    this.workerReady = false;
    this.resetSessionControls();
    this.snapshot.engine = EnginePhase.Failed;
    this.snapshot.engineText = this.uiCopy('本地运行时启动失败');
    this.snapshot.failure = this.clean(message);
    this.snapshot.running = false;
    this.pendingTurns = 0;
    this.clearQueueState();
    this.emit();
  }

  // -------------------------------------------------------------- shell nav

  navigate(page: Page, id?: string): void {
    if (page === Page.Chat) {
      if (id !== undefined && id.length > 0) {
        this.openSession(id).catch((error: Error) => {
          this.snapshot.failure = this.clean(errorText(error));
          this.emit();
        });
        return;
      }
      this.resetNavigation();
      this.emit();
      this.loadForPage().catch((error: Error) => {
        this.snapshot.failure = this.clean(errorText(error));
        this.emit();
      });
      return;
    }
    if (page === Page.Sessions && id !== undefined && id.length > 0) {
      this.openSession(id).catch((error: Error) => {
        this.snapshot.failure = this.clean(errorText(error));
        this.emit();
      });
      return;
    }
    this.pushNavigationFrame(this.navigationFrame(page, id));
    this.emit();
    this.loadForPage().catch((error: Error) => {
      this.snapshot.failure = this.clean(errorText(error));
      this.emit();
    });
  }

  back(): void {
    if (!navCanGoBack(this.valueStack)) {
      // The root is a fixed point. If a caller ever left the snapshot on a
      // nested page without a frame, repair it instead of freezing there.
      if (this.snapshot.page === Page.Chat) {
        return;
      }
      this.resetNavigation();
    } else {
      this.valueStack = navPopFrame(this.valueStack);
      this.applyNavigationFrame(navCurrentFrame(this.valueStack));
    }
    this.snapshot.failure = '';
    this.emit();
    this.loadForPage().catch((error: Error) => {
      this.snapshot.failure = this.clean(errorText(error));
      this.emit();
    });
  }

  private navigationFrame(page: Page, id?: string): NavigationFrame {
    const routeId = id === undefined ? '' : id;
    if (page === Page.Files) {
      const path = routeId.length > 0 ? routeId : this.snapshot.filePath;
      return navFilesFrame(path);
    }
    if (page === Page.Preview) {
      const path = routeId.length > 0 ? routeId : this.snapshot.previewPath;
      const directory = this.snapshot.page === Page.Files ? this.snapshot.filePath : '';
      return navPreviewFrame(path, directory);
    }
    return new NavigationFrame(page, routeId, '');
  }

  private pushNavigationFrame(frame: NavigationFrame): void {
    this.valueStack = navPushFrame(this.valueStack, frame);
    this.applyNavigationFrame(frame);
  }

  private applyNavigationFrame(frame: NavigationFrame): void {
    this.snapshot.page = frame.page;
    if (frame.page === Page.Files) {
      const path = frame.filePath.length > 0 ? frame.filePath : frame.id;
      if (path.length > 0) {
        this.snapshot.filePath = path;
      }
    } else if (frame.page === Page.Preview) {
      if (frame.id.length > 0) {
        this.snapshot.previewPath = frame.id;
      }
      if (frame.filePath.length > 0) {
        this.snapshot.filePath = frame.filePath;
      }
    } else if (frame.page === Page.WorkspaceFolders && frame.id.length > 0) {
      this.snapshot.activeFolderId = frame.id;
    }
  }

  private resetNavigation(): void {
    this.valueStack = navReset();
    this.applyNavigationFrame(navCurrentFrame(this.valueStack));
  }

  clearNotice(): void {
    this.snapshot.notice = '';
    this.snapshot.failure = '';
    this.emit();
  }

  setDraft(text: string): void {
    this.snapshot.draft = text;
    if (this.snapshot.activeSessionId.length > 0) {
      this.drafts.set(this.snapshot.activeSessionId, text);
    }
    this.persistSoon();
    this.emit();
  }

  async send(text: string): Promise<void> {
    const prompt = text.trim();
    if (prompt.length === 0) {
      return;
    }
    if (!await this.ensureRpcReady(30000)) {
      this.snapshot.draft = text;
      this.snapshot.notice = this.uiCopy('本地运行时还没就绪；草稿已保留。');
      this.emit();
      return;
    }
    let session = this.activeSession();
    if (session === null) {
      session = this.createLocalSession('新会话');
    }
    if (!await this.ensureWorkerSession(session)) {
      this.snapshot.draft = text;
      this.snapshot.notice = this.uiCopy('Worker 会话尚未建立；草稿已保留。');
      this.emit();
      return;
    }
    const attachments = this.snapshot.attachmentPaths.slice();
    if (prompt.startsWith('/') && attachments.length === 0) {
      await this.refreshCommands();
    }
    if (isRegisteredSlashCommand(prompt, attachments.length > 0, this.snapshot.commands)) {
      await this.executeComposerCommand(prompt, session);
      return;
    }
    const mode = this.snapshot.running && this.snapshot.settings.busyEnter === 'steer' ? 'steer' : 'queue';
    const finalPrompt = this.withAttachments(prompt, attachments);
    const requestId = uniqueId('prompt');
    if (this.snapshot.running) {
      await this.sendWhileRunning(session, requestId, prompt, finalPrompt, mode);
      return;
    }
    const userRow = new ChatRow();
    userRow.id = uniqueId('row');
    userRow.kind = RowKind.User;
    userRow.text = prompt;
    userRow.status = 'running';
    userRow.createdAt = Date.now();
    this.resetNavigation();
    this.snapshot.draft = '';
    this.snapshot.failure = '';
    this.snapshot.notice = '';
    this.appendRow(userRow);
    if (session.title === '新会话' || session.title.length === 0) {
      session.title = this.titleFor(prompt);
      this.snapshot.title = session.title;
    }
    if (this.pendingTurns === 0) {
      this.beginArtifacts(session);
    }
    this.pendingTurns = this.pendingTurns + 1;
    this.snapshot.running = true;
    this.snapshot.stopping = false;
    this.snapshot.streamingText = '';
    this.snapshot.reasoningText = '';
    this.emit();
    let submitted = false;
    try {
      await this.ensureEventStream();
    } catch (eventError) {
      this.snapshot.notice = this.uiFill('实时审批事件流不可用：{0}', [this.clean(errorText(eventError as Error))]);
    }
    try {
      await this.openFollow(session);
      await this.promptOnce(requestId, session, finalPrompt, mode);
      submitted = true;
    } catch (error) {
      const first = this.clean(errorText(error as Error));
      if (this.workerSessionGone(first)) {
        session.workerSessionId = '';
        this.snapshot.notice = CONTEXT_LOST;
        try {
          if (!await this.ensureWorkerSession(session)) {
            throw new Error(first);
          }
          await this.closeActiveStream();
          await this.openFollow(session);
          await this.promptOnce(requestId, session, finalPrompt, mode);
          submitted = true;
        } catch (retryError) {
          this.failSend(text, this.clean(errorText(retryError as Error)));
          return;
        }
      } else {
        this.failSend(text, first);
        return;
      }
    }
    if (submitted) {
      this.snapshot.attachmentPaths = [];
      this.persistNow();
      await this.refreshQueueFor(session.workerSessionId);
      this.emit();
    }
  }

  /**
   * Busy queue/steer submission. The transcript stays owned by the Worker: this
   * only publishes a local echo tied to the real prompt requestId. It is
   * retired later by a durable `source.rpcId` or an admitted user/message.
   */
  private async sendWhileRunning(session: SessionRecord, requestId: string, text: string,
    finalPrompt: string, mode: string): Promise<void> {
    const generation = this.queueGeneration;
    const workerSessionId = session.workerSessionId;
    const lane = mode === 'steer' ? 'steered' : 'next-turn';
    const echo = localQueueEcho(session.workerSessionId, requestId, text, lane);
    const echoes = this.snapshot.localQueueItems.filter(
      (item: QueueItem) => item.promptRequestId !== requestId);
    this.snapshot.localQueueItems = echoes.concat([echo]);
    this.snapshot.draft = '';
    this.snapshot.failure = '';
    this.snapshot.notice = '';
    this.snapshot.stopping = false;
    if (this.snapshot.running) {
      // A steer joins the current turn. Only a real queued turn increases the
      // expected turn count used by artifact ranges and cancel guards.
      if (mode !== 'steer') {
        if (this.pendingTurns === 0) {
          this.beginArtifacts(session);
        }
        this.pendingTurns = this.pendingTurns + 1;
        if (!this.pendingOwnQueueRequestIds.includes(requestId)) {
          this.pendingOwnQueueRequestIds.push(requestId);
        }
      }
    }
    if (session.title === '新会话' || session.title.length === 0) {
      session.title = this.titleFor(text);
      this.snapshot.title = session.title;
    }
    this.emit();
    try {
      await this.ensureEventStream();
    } catch (eventError) {
      this.snapshot.notice = this.uiFill('实时审批事件流不可用：{0}',
        [this.clean(errorText(eventError as Error))]);
    }
    try {
      await this.openFollow(session);
      await this.promptOnce(requestId, session, finalPrompt, mode);
    } catch (error) {
      const message = this.clean(errorText(error as Error));
      // An accepted prompt can lose its response. Durable source.rpcId is the
      // only proof that the echo succeeded; text is never a correlation key.
      const accepted = await this.fetchQueueProjection(workerSessionId);
      if (!this.queueStillCurrent(generation, workerSessionId)) {
        return;
      }
      if (accepted.items !== null && containsPromptRequestId(accepted.items, requestId)) {
        this.applyQueueResult(workerSessionId, generation, accepted);
        this.snapshot.localQueueItems = acknowledgeLocalQueuePrompt(
          this.snapshot.localQueueItems, requestId);
        if (mode !== 'steer') {
          this.snapshot.attachmentPaths = [];
        }
        this.persistNow();
        this.emit();
        return;
      }
      // A user/message admitted the prompt while the response was in flight;
      // the event retired this exact echo by rpcId. Do not report failure or
      // restore a duplicate draft for a turn that already exists.
      if (!this.hasLocalQueueRequest(requestId)) {
        this.persistNow();
        this.emit();
        return;
      }
      this.failBusySend(text, requestId, mode, message);
      return;
    }
    if (!this.queueStillCurrent(generation, workerSessionId)) {
      return;
    }
    this.snapshot.localQueueItems = acknowledgeLocalQueuePrompt(this.snapshot.localQueueItems, requestId);
    this.snapshot.attachmentPaths = [];
    this.persistNow();
    await this.refreshQueueFor(workerSessionId);
    this.emit();
  }

  /**
   * Mutate one durable next-turn row. The RPC acceptance is not success: the
   * same sequenced projection must confirm the edit, removal or real steer.
   */
  async updateQueueItem(workerSessionId: string, itemId: string, action: QueueItemAction,
    replacement?: string): Promise<void> {
    const session = this.activeSession();
    if (session === null || workerSessionId.length === 0 ||
      session.workerSessionId !== workerSessionId || itemId.length === 0) {
      return;
    }
    const rows = this.snapshot.queueItems;
    if (rows === null) {
      throw new Error(this.uiCopy('队列状态未知，不能执行队列操作。'));
    }
    const target = durableQueueItemById(rows, itemId);
    if (target === null || target.busy || target.workerSessionId !== workerSessionId) {
      return;
    }
    const text = replacement === undefined ? '' : replacement;
    if (action === QueueItemAction.Edit) {
      if (!target.canEdit || text.trim().length === 0) {
        return;
      }
    } else if (action === QueueItemAction.Remove) {
      if (!target.canRemove) {
        return;
      }
    } else if (action === QueueItemAction.Steer) {
      if (!target.canSteer) {
        return;
      }
    } else {
      return;
    }
    const args = encodeQueueUpdate(workerSessionId, itemId, action, text);
    if (args === null) {
      return;
    }
    const generation = this.queueGeneration;
    const previousLane = target.lane;
    const ownedRequestId = target.promptRequestId;
    this.markQueueBusy(itemId, action);
    this.emit();
    let callFailure = '';
    try {
      await this.pageBridge.call('session/updateQueue', args as Object, 15000);
    } catch (error) {
      callFailure = this.clean(errorText(error as Error));
    }
    if (!this.queueStillCurrent(generation, workerSessionId)) {
      return;
    }
    const fresh = await this.fetchQueueProjection(workerSessionId);
    if (!this.queueStillCurrent(generation, workerSessionId)) {
      return;
    }
    if (fresh.items === null) {
      this.snapshot.queueItems = null;
      this.snapshot.queueFailure = this.queueFailureText(fresh.failure);
      this.emit();
      if (callFailure.length > 0) {
        throw new Error(this.uiFill('队列操作未确认：{0}', [callFailure]));
      }
      throw new Error(this.uiCopy('队列操作已提交，但无法重新读取队列确认结果。'));
    }
    this.applyQueueRead(workerSessionId, generation, fresh.items);
    if (callFailure.length > 0) {
      const stillThere = durableQueueItemById(this.snapshot.queueItems, itemId);
      const targetGone = callFailure.includes('session/queue-item-not-found');
      if (stillThere !== null) {
        this.markQueueFailure(itemId, callFailure, action);
        this.emit();
        throw new Error(this.uiFill('队列操作未确认：{0}', [callFailure]));
      }
      if (action === QueueItemAction.Steer && callFailure.includes('session/steer-unavailable')) {
        this.emit();
        return;
      }
      // A disappeared target is the authoritative remove/admit outcome. It is
      // not proof of an edited/steered row, so no success is published.
      this.clearQueueRow(itemId);
      this.emit();
      if (!targetGone) {
        throw new Error(this.uiFill('队列操作未确认：{0}', [callFailure]));
      }
      return;
    }
    const confirmed = queueActionConfirmed(action, itemId, previousLane, text, this.snapshot.queueItems);
    if (!confirmed) {
      this.markQueueFailure(itemId,
        this.uiCopy('队列操作没有被 Worker 的 sequenced projection 确认'), action);
      this.emit();
      throw new Error(this.uiCopy('队列操作没有被 Worker 确认。'));
    }
    if (action === QueueItemAction.Remove) {
      this.retireOwnedQueueTurn(ownedRequestId);
    }
    this.clearQueueActionRow(itemId);
    this.emit();
  }

  private markQueueBusy(itemId: string, action: QueueItemAction): void {
    const rows = this.snapshot.queueItems;
    if (rows === null) {
      return;
    }
    for (let index = 0; index < rows.length; index++) {
      const row = rows[index];
      if (row.origin === QueueOrigin.Durable && row.id === itemId) {
        row.busy = true;
        row.action = action;
        row.failure = '';
        row.state = QueueItemState.Ready;
      }
    }
  }

  private markQueueFailure(itemId: string, message: string, action: QueueItemAction): void {
    const rows = this.snapshot.queueItems;
    if (rows === null) {
      return;
    }
    for (let index = 0; index < rows.length; index++) {
      const row = rows[index];
      if (row.origin === QueueOrigin.Durable && row.id === itemId) {
        row.busy = false;
        row.action = action;
        row.failure = message;
        row.state = QueueItemState.Failed;
      }
    }
  }

  private clearQueueActionRow(itemId: string): void {
    const rows = this.snapshot.queueItems;
    if (rows === null) {
      return;
    }
    for (let index = 0; index < rows.length; index++) {
      const row = rows[index];
      if (row.origin === QueueOrigin.Durable && row.id === itemId) {
        row.busy = false;
        row.action = '';
        row.failure = '';
        row.state = QueueItemState.Ready;
      }
    }
  }

  private clearQueueRow(itemId: string): void {
    const rows = this.snapshot.queueItems;
    if (rows === null) {
      return;
    }
    const next: QueueItem[] = [];
    for (let index = 0; index < rows.length; index++) {
      if (rows[index].id !== itemId || rows[index].origin !== QueueOrigin.Durable) {
        next.push(rows[index]);
      }
    }
    this.snapshot.queueItems = next;
  }

  private retireOwnedQueueTurn(promptRequestId: string): void {
    const retired = retireOwnedQueueRequest(this.pendingOwnQueueRequestIds, promptRequestId);
    this.pendingOwnQueueRequestIds = retired.remaining;
    if (!retired.removed || this.pendingTurns === 0) {
      return;
    }
    this.pendingTurns = this.pendingTurns - 1;
    this.snapshot.running = this.pendingTurns > 0;
    if (this.pendingTurns === 0) {
      this.pendingOwnQueueRequestIds = [];
      this.endArtifacts();
      this.closeActiveStream();
    }
  }

  private hasLocalQueueRequest(promptRequestId: string): boolean {
    for (let index = 0; index < this.snapshot.localQueueItems.length; index++) {
      if (this.snapshot.localQueueItems[index].promptRequestId === promptRequestId) {
        return true;
      }
    }
    return false;
  }

  private failBusySend(text: string, requestId: string, mode: string, message: string): void {
    if (mode !== 'steer') {
      const retired = retireOwnedQueueRequest(this.pendingOwnQueueRequestIds, requestId);
      this.pendingOwnQueueRequestIds = retired.remaining;
      if (retired.removed && this.pendingTurns > 0) {
        this.pendingTurns = this.pendingTurns - 1;
        this.snapshot.running = this.pendingTurns > 0;
      }
    }
    this.snapshot.localQueueItems = failLocalQueuePrompt(this.snapshot.localQueueItems, requestId, message);
    this.snapshot.draft = text;
    if (this.snapshot.activeSessionId.length > 0) {
      this.drafts.set(this.snapshot.activeSessionId, text);
    }
    this.snapshot.failure = this.uiFill('发送失败：{0}', [message]);
    if (this.pendingTurns === 0) {
      this.pendingOwnQueueRequestIds = [];
      this.endArtifacts();
      this.closeActiveStream();
    }
    this.persistNow();
    this.emit();
  }

  /**
   * Android `runChatCommand`: dispatch a registered slash line through
   * `commands/execute`, never `session/prompt`. A missing or `error` result
   * keeps the draft; success reports the Worker text and refreshes projections.
   */
  private async executeComposerCommand(line: string, session: SessionRecord): Promise<void> {
    const draft = this.snapshot.draft;
    const args: Record<string, Object> = {};
    args['agentId'] = session.workerSessionId;
    args['line'] = line;
    const submittedAttachments: Object[] = [];
    args['submittedAttachments'] = submittedAttachments;
    try {
      const value = await this.pageBridge.call('commands/execute', args as Object, 30000);
      let root = asRecord(value);
      const unwrapped = this.remoteValue(root);
      if (unwrapped !== null) {
        root = unwrapped;
      }
      const execution: ComposerCommandExecution = parseCommandExecution(root);
      if (!execution.accepted) {
        this.snapshot.draft = draft.trim().length > 0 ? draft : line;
        this.snapshot.notice = '命令没有执行成功，请重试。';
        this.emit();
        return;
      }
      this.snapshot.lastCommandId = execution.commandId;
      if (this.snapshot.draft.trim() === line) {
        this.snapshot.draft = '';
      }
      this.snapshot.notice = execution.text;
      await this.refreshSessionControls();
      this.persistNow();
      this.emit();
    } catch (error) {
      this.snapshot.draft = draft.trim().length > 0 ? draft : line;
      this.snapshot.notice = '命令没有执行成功，请重试。';
      this.emit();
    }
  }

  async stopTurn(): Promise<void> {
    if (!this.snapshot.running && this.pendingTurns === 0) {
      this.snapshot.stopping = false;
      this.snapshot.notice = this.uiCopy('当前没有运行中的轮次');
      this.emit();
      return;
    }
    const session = this.activeSession();
    if (session === null || session.workerSessionId.length === 0) {
      this.snapshot.running = false;
      this.pendingTurns = 0;
      this.endArtifacts();
      this.clearQueueState();
      this.snapshot.stopping = false;
      this.emit();
      return;
    }
    this.snapshot.stopping = true;
    this.emit();
    const request: SessionCancelRequest = { sessionId: session.workerSessionId };
    const args: SessionCancelArgs = { request: request };
    try {
      await this.pageBridge.call('session/cancel', args as Object, 15000);
      this.armStopTimeout();
    } catch (error) {
      this.snapshot.stopping = false;
      this.snapshot.failure = this.uiFill('取消请求未送达：{0}', [this.clean(errorText(error as Error))]);
      this.emit();
    }
  }

  async newSession(folderId?: string): Promise<void> {
    if (this.snapshot.running) {
      this.snapshot.notice = this.uiCopy('本轮仍在运行；请先停止或等待结束后再新建会话。');
      this.emit();
      return;
    }
    const folder = folderId !== undefined && folderId.length > 0 ? folderId : this.snapshot.activeFolderId;
    const previousSessions = this.cloneSessions(this.snapshot.sessions);
    const previousActiveSessionId = this.snapshot.activeSessionId;
    const previousActiveFolderId = this.snapshot.activeFolderId;
    const previousTitle = this.snapshot.title;
    const previousRows = this.cloneRows(this.snapshot.rows);
    const previousDraft = this.snapshot.draft;
    const previousStack = this.valueStack;
    this.closeActiveStream();
    const created = this.createLocalSession('新会话', folder);
    this.resetNavigation();
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      this.snapshot.sessions = previousSessions;
      this.snapshot.activeSessionId = previousActiveSessionId;
      this.snapshot.activeFolderId = previousActiveFolderId;
      this.snapshot.title = previousTitle;
      this.snapshot.rows = previousRows;
      this.snapshot.draft = previousDraft;
      this.drafts.delete(created.id);
      this.valueStack = previousStack;
      this.applyNavigationFrame(navCurrentFrame(previousStack));
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.clearVisiblePending();
    this.clearQueueState();
    this.resetSessionControls();
    this.emit();
    this.refreshControlsQuietly();
  }

  async openSession(id: string): Promise<void> {
    if (this.snapshot.running && id !== this.snapshot.activeSessionId) {
      this.snapshot.notice = this.uiCopy('本轮仍在运行；停止后才能切换会话。');
      this.emit();
      return;
    }
    const session = this.findSession(id);
    if (session === null) {
      this.snapshot.notice = this.uiCopy('找不到这个会话');
      this.emit();
      return;
    }
    const previousActiveSessionId = this.snapshot.activeSessionId;
    const previousActiveFolderId = this.snapshot.activeFolderId;
    const previousTitle = this.snapshot.title;
    const previousRows = this.cloneRows(this.snapshot.rows);
    const previousDraft = this.snapshot.draft;
    const previousStack = this.valueStack;
    this.snapshot.activeSessionId = session.id;
    this.snapshot.activeFolderId = session.folderId;
    this.snapshot.title = session.title;
    this.snapshot.rows = this.cloneRows(session.rows);
    const draft = this.drafts.get(session.id);
    this.snapshot.draft = draft === undefined ? '' : draft;
    this.resetNavigation();
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      this.snapshot.activeSessionId = previousActiveSessionId;
      this.snapshot.activeFolderId = previousActiveFolderId;
      this.snapshot.title = previousTitle;
      this.snapshot.rows = previousRows;
      this.snapshot.draft = previousDraft;
      this.valueStack = previousStack;
      this.applyNavigationFrame(navCurrentFrame(previousStack));
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.snapshot.failure = '';
    if (previousActiveSessionId !== session.id) {
      this.clearVisiblePending();
      this.clearQueueState();
    }
    this.resetSessionControls();
    this.emit();
    this.refreshControlsQuietly();
  }

  async renameSession(id: string, title: string): Promise<void> {
    const session = this.findSession(id);
    const cleanTitle = title.trim();
    if (session === null || cleanTitle.length === 0) {
      this.snapshot.notice = this.uiCopy('会话标题不能为空');
      this.emit();
      return;
    }
    const previousTitle = session.title;
    const previousUpdatedAt = session.updatedAt;
    const previousSnapshotTitle = this.snapshot.title;
    session.title = cleanTitle;
    session.updatedAt = Date.now();
    if (id === this.snapshot.activeSessionId) {
      this.snapshot.title = cleanTitle;
    }
    this.sortSessions();
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      session.title = previousTitle;
      session.updatedAt = previousUpdatedAt;
      this.snapshot.title = previousSnapshotTitle;
      this.sortSessions();
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.emit();
  }

  async pinSession(id: string, pinned: boolean): Promise<void> {
    const session = this.findSession(id);
    if (session === null) {
      return;
    }
    const previousPinned = session.pinned;
    session.pinned = pinned;
    this.sortSessions();
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      session.pinned = previousPinned;
      this.sortSessions();
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.emit();
  }

  async archiveSession(id: string, archived: boolean): Promise<void> {
    if (this.snapshot.running && id === this.snapshot.activeSessionId) {
      this.snapshot.notice = this.uiCopy('本轮仍在运行；停止后才能归档当前会话。');
      this.emit();
      return;
    }
    const session = this.findSession(id);
    if (session === null) {
      return;
    }
    const previousSessions = this.cloneSessions(this.snapshot.sessions);
    const previousActiveSessionId = this.snapshot.activeSessionId;
    const previousActiveFolderId = this.snapshot.activeFolderId;
    const previousTitle = this.snapshot.title;
    const previousRows = this.cloneRows(this.snapshot.rows);
    const previousDraft = this.snapshot.draft;
    session.archived = archived;
    if (archived && this.snapshot.activeSessionId === id) {
      this.selectFallbackSession();
    }
    this.sortSessions();
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      this.snapshot.sessions = previousSessions;
      this.snapshot.activeSessionId = previousActiveSessionId;
      this.snapshot.activeFolderId = previousActiveFolderId;
      this.snapshot.title = previousTitle;
      this.snapshot.rows = previousRows;
      this.snapshot.draft = previousDraft;
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.emit();
  }

  async deleteSession(id: string): Promise<void> {
    if (this.snapshot.running && id === this.snapshot.activeSessionId) {
      this.snapshot.notice = this.uiCopy('本轮仍在运行；请先停止再删除会话。');
      this.emit();
      return;
    }
    const next: SessionRecord[] = [];
    let removed = false;
    for (let index = 0; index < this.snapshot.sessions.length; index++) {
      const session = this.snapshot.sessions[index];
      if (session.id === id) {
        removed = true;
        continue;
      }
      next.push(session);
    }
    if (!removed) {
      return;
    }
    const previousSessions = this.cloneSessions(this.snapshot.sessions);
    const previousActiveSessionId = this.snapshot.activeSessionId;
    const previousActiveFolderId = this.snapshot.activeFolderId;
    const previousTitle = this.snapshot.title;
    const previousRows = this.cloneRows(this.snapshot.rows);
    const previousDraft = this.snapshot.draft;
    const removedDraft = this.drafts.get(id);
    this.snapshot.sessions = next;
    this.drafts.delete(id);
    if (this.snapshot.activeSessionId === id) {
      this.selectFallbackSession();
    }
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      this.snapshot.sessions = previousSessions;
      this.snapshot.activeSessionId = previousActiveSessionId;
      this.snapshot.activeFolderId = previousActiveFolderId;
      this.snapshot.title = previousTitle;
      this.snapshot.rows = previousRows;
      this.snapshot.draft = previousDraft;
      if (removedDraft !== undefined) {
        this.drafts.set(id, removedDraft);
      }
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.emit();
  }

  async createFolder(name: string): Promise<void> {
    const cleanName = name.trim();
    if (cleanName.length === 0) {
      this.snapshot.notice = this.uiCopy('文件夹名不能为空');
      this.emit();
      return;
    }
    const previousFolders = this.cloneFolders(this.snapshot.folders);
    const previousActiveFolderId = this.snapshot.activeFolderId;
    const workspace = new Workspace();
    workspace.id = uniqueId('folder');
    workspace.name = cleanName;
    workspace.path = '/dsh/workspace';
    this.snapshot.folders.push(workspace);
    this.snapshot.activeFolderId = workspace.id;
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      this.snapshot.folders = previousFolders;
      this.snapshot.activeFolderId = previousActiveFolderId;
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.emit();
  }

  async renameFolder(id: string, name: string): Promise<void> {
    const cleanName = name.trim();
    if (cleanName.length === 0) {
      return;
    }
    for (let index = 0; index < this.snapshot.folders.length; index++) {
      if (this.snapshot.folders[index].id === id) {
        const previousName = this.snapshot.folders[index].name;
        this.snapshot.folders[index].name = cleanName;
        const outcome = this.persistChatsOutcome();
        if (!outcome.ok) {
          this.snapshot.folders[index].name = previousName;
          this.lastPersistError = outcome.error;
          this.snapshot.failure = outcome.error;
          this.emit();
          throw new Error(outcome.error);
        }
        this.emit();
        return;
      }
    }
  }

  async deleteFolder(id: string): Promise<void> {
    if (id === 'default') {
      this.snapshot.notice = this.uiCopy('默认文件夹不能删除');
      this.emit();
      return;
    }
    const previousFolders = this.cloneFolders(this.snapshot.folders);
    const previousSessions = this.cloneSessions(this.snapshot.sessions);
    const previousActiveFolderId = this.snapshot.activeFolderId;
    const next: Workspace[] = [];
    for (let index = 0; index < this.snapshot.folders.length; index++) {
      if (this.snapshot.folders[index].id !== id) {
        next.push(this.snapshot.folders[index]);
      }
    }
    this.snapshot.folders = next;
    for (let index = 0; index < this.snapshot.sessions.length; index++) {
      if (this.snapshot.sessions[index].folderId === id) {
        this.snapshot.sessions[index].folderId = 'default';
      }
    }
    if (this.snapshot.activeFolderId === id) {
      this.snapshot.activeFolderId = 'default';
    }
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      this.snapshot.folders = previousFolders;
      this.snapshot.sessions = previousSessions;
      this.snapshot.activeFolderId = previousActiveFolderId;
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.emit();
  }

  async selectFolder(id: string): Promise<void> {
    const previousActiveFolderId = this.snapshot.activeFolderId;
    this.snapshot.activeFolderId = id;
    const outcome = this.persistChatsOutcome();
    if (!outcome.ok) {
      this.snapshot.activeFolderId = previousActiveFolderId;
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    this.emit();
  }

  // ------------------------------------------------------------ provider

  /**
   * Upsert a profile document row. Metadata is fully validated before the
   * document is written; a key is validated before too, so a rejected key can
   * never leave a half-saved service. A persisted profile and a failed key
   * write is reported as such, never as a completed save.
   */
  async saveProviderProfile(profile: ProviderProfileRecord, key: string, isNew: boolean): Promise<void> {
    const state = this.providerState();
    const requestedId = profile.id.trim();
    let previous: ProviderProfileRecord | null = null;
    if (isNew) {
      if (requestedId.length > 0 && findProviderProfile(state, requestedId) !== null) {
        this.rejectProvider(this.uiCopy('这个模型服务标识已存在；本次未覆盖现有服务'));
      }
    } else {
      previous = findProviderProfile(state, requestedId);
      if (previous === null) {
        this.rejectProvider(this.uiCopy('这个模型服务已不存在；请重新载入后再保存'));
      }
    }
    const keyText = key.trim();
    if (keyText.length > 0) {
      const keyRejection = providerKeyRejection(keyText);
      if (keyRejection.length > 0) {
        this.rejectProvider(keyRejection);
      }
    }
    const draft = cloneProviderProfile(profile);
    draft.id = requestedId.length > 0 ? requestedId : this.nextProviderId(state);
    draft.name = draft.name.trim();
    draft.baseUrl = draft.baseUrl.trim();
    draft.model = draft.model.trim();
    draft.encoder = draft.encoder.trim().length > 0 ? draft.encoder.trim() : 'deepseek';
    draft.effort = draft.effort.trim().length > 0 ? draft.effort.trim() : 'high';
    draft.reasoningEffort = draft.reasoningEffort.trim().length > 0
      ? draft.reasoningEffort.trim()
      : draft.effort;
    const rejection = providerProfileRejection(draft);
    if (rejection.length > 0) {
      this.rejectProvider(rejection);
    }
    if (previous !== null) {
      const previousRef = previous.credentialRef.trim();
      draft.credentialRef = previousRef.length > 0 ? previousRef : providerCredentialAlias(draft);
      draft.keyConfigured = previous.keyConfigured;
    } else {
      draft.credentialRef = providerCredentialAlias(draft);
      draft.keyConfigured = false;
    }
    const next = withUpsertedProviderProfile(state, draft, isNew);
    const outcome = this.persistSettingsOutcome(this.settingsForProvider(next));
    if (!outcome.ok) {
      this.rejectProvider(outcome.error);
    }
    this.applyProviderState(next);
    const alias = providerCredentialAlias(draft);
    let keyLine = '';
    if (keyText.length > 0) {
      const written: KeyWriteResult = await this.secure.save(alias, keyText);
      if (!written.ok) {
        const message = '配置已保存；密钥写入失败，本次未确认密钥';
        this.snapshot.failure = message;
        this.snapshot.notice = '';
        this.emit();
        throw new Error(message);
      }
      const readback: KeyReadResult = await this.secure.read(alias);
      if (readback.status !== 'ok' || readback.value !== keyText) {
        const message = '配置已保存；密钥写入后读取确认失败，本次未确认密钥变更';
        this.snapshot.failure = message;
        this.snapshot.notice = '';
        this.emit();
        throw new Error(message);
      }
      keyLine = '，密钥已保存';
      this.updateProviderKeyFact(draft.id, true);
    } else if (previous === null) {
      const existingKey: KeyReadResult = await this.secure.read(alias);
      this.updateProviderKeyFact(draft.id, existingKey.status === 'ok');
    }
    this.snapshot.notice = this.uiFill('已保存到本机：模型服务{0}（下次启动本地引擎时生效）', [keyLine]);
    this.snapshot.failure = '';
    this.lastPersistError = '';
    this.emit();
  }

  async selectProviderProfile(id: string): Promise<void> {
    const next = withSelectedProviderProfile(this.providerState(), id);
    if (next === null) {
      this.snapshot.failure = this.uiCopy('这个模型服务已经不存在');
      this.snapshot.notice = '';
      this.emit();
      throw new Error('这个模型服务已经不存在');
    }
    const outcome = this.persistSettingsOutcome(this.settingsForProvider(next));
    if (!outcome.ok) {
      this.rejectProvider(outcome.error);
    }
    this.applyProviderState(next);
    this.snapshot.notice = this.uiCopy('已选择模型服务；将在下次启动本地引擎时生效。');
    this.snapshot.failure = '';
    this.lastPersistError = '';
    this.emit();
  }

  /**
   * Delete one saved profile and only that profile's AssetStore alias. The
   * profile that the running Worker booted with is refused with an explicit
   * message rather than having its live key removed underneath it.
   */
  async deleteProviderProfile(id: string): Promise<void> {
    const state = this.providerState();
    const profile = findProviderProfile(state, id);
    if (profile === null) {
      this.snapshot.failure = this.uiCopy('只能删除本机保存的模型服务；启动配置的服务不能删除');
      this.snapshot.notice = '';
      this.emit();
      throw new Error('只能删除本机保存的模型服务；启动配置的服务不能删除');
    }
    if (this.nativeRunning && this.bootProvider !== null && this.bootProvider.id === profile.id) {
      this.rejectProvider(this.uiCopy('这是当前运行中的模型服务；请先停止本地引擎再删除，本次未删除'));
    }
    const alias = providerCredentialAlias(profile);
    const read: KeyReadResult = await this.secure.read(alias);
    if (read.status === 'unreadable') {
      this.rejectProvider(this.uiCopy('无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试'));
    }
    const removed: KeyWriteResult = await this.secure.remove(alias);
    if (!removed.ok) {
      this.rejectProvider(this.uiCopy('密钥删除没有确认；模型服务未删除，请重试'));
    }
    const next = withDeletedProviderProfile(state, id);
    const outcome = this.persistSettingsOutcome(this.settingsForProvider(next));
    if (!outcome.ok) {
      const message = '密钥已删除；模型服务配置未删除，请刷新后重试';
      this.snapshot.failure = message;
      this.emit();
      throw new Error(message);
    }
    this.applyProviderState(next);
    this.snapshot.notice = this.uiCopy('已删除本机保存的模型服务与密钥');
    this.snapshot.failure = '';
    this.lastPersistError = '';
    this.emit();
  }

  /**
   * Test one saved profile through a separate proxy instance. The active
   * proxy's route and key binding are untouched, so testing an alternative
   * profile can never reroute the running Worker.
   */
  async testProviderProfile(id: string): Promise<void> {
    const state = this.providerState();
    const wanted = id.trim();
    const profile = wanted.length > 0 ? findProviderProfile(state, wanted) : selectedProviderProfile(state);
    if (profile === null) {
      this.snapshot.failure = this.uiCopy('请先保存这个模型服务，再测试连接');
      this.snapshot.notice = '';
      this.emit();
      throw new Error('请先保存这个模型服务，再测试连接');
    }
    const route = new ModelRouteConfig();
    route.baseUrl = profile.baseUrl;
    route.model = profile.model;
    route.encoder = profile.encoder;
    const probe = new HostHttpProxy();
    probe.setRoute(route);
    probe.setKeyProvider(async (): Promise<string> => {
      const result: KeyReadResult = await this.secure.read(providerCredentialAlias(profile));
      if (result.status === 'unreadable') {
        throw new Error('credential_unavailable');
      }
      return result.status === 'ok' ? result.value : '';
    });
    let result: ProviderProbeResult = new ProviderProbeResult();
    try {
      result = await probe.testProvider();
    } finally {
      probe.dispose();
    }
    this.snapshot.detail = `provider test: HTTP ${result.status}`;
    this.snapshot.notice = result.message;
    if (!result.ok) {
      this.snapshot.failure = result.message;
      this.emit();
      throw new Error(result.message);
    }
    this.snapshot.failure = '';
    this.emit();
  }

  async saveProvider(provider: ProviderConfig, key: string): Promise<void> {
    const draft = new ProviderProfileRecord();
    draft.id = provider.id;
    draft.name = provider.name;
    draft.baseUrl = provider.baseUrl;
    draft.model = provider.model;
    draft.encoder = provider.encoder;
    draft.effort = provider.effort;
    draft.reasoningEffort = provider.effort;
    const existing = findProviderProfile(this.providerState(), provider.id.trim());
    await this.saveProviderProfile(draft, key, existing === null);
  }

  async deleteProviderKey(): Promise<void> {
    const state = this.providerState();
    const profile = selectedProviderProfile(state);
    if (profile === null) {
      this.snapshot.failure = this.uiCopy('没有可删除密钥的模型服务');
      this.snapshot.notice = '';
      this.emit();
      throw new Error('没有可删除密钥的模型服务');
    }
    if (this.nativeRunning && this.bootProvider !== null && this.bootProvider.id === profile.id) {
      this.rejectProvider(this.uiCopy('这是当前运行中的模型服务；请先停止本地引擎再删除密钥，本次未删除'));
    }
    const alias = providerCredentialAlias(profile);
    const read: KeyReadResult = await this.secure.read(alias);
    if (read.status === 'unreadable') {
      this.rejectProvider(this.uiCopy('无法读取此设备的密钥，不能删除密钥。请解锁设备后重新载入页面再试'));
    }
    const removed: KeyWriteResult = await this.secure.remove(alias);
    if (!removed.ok) {
      this.rejectProvider(removed.reason.length > 0 ? removed.reason : '密钥存储无法删除');
    }
    this.updateProviderKeyFact(profile.id, false);
    this.snapshot.notice = this.uiCopy('已删除此模型服务保存在 AssetStore 的密钥。');
    this.snapshot.failure = '';
    this.lastPersistError = '';
    this.emit();
  }

  async testProvider(): Promise<void> {
    await this.testProviderProfile(this.snapshot.settings.selectedProviderId);
  }

  async saveSettings(settings: Settings): Promise<void> {
    const previous = this.cloneSettings(this.snapshot.settings);
    const previousPermission = previous.permission;
    const next = this.cloneSettings(settings);
    // Provider selection and profiles are owned by the provider actions above;
    // a settings draft can never overwrite them with a stale clone.
    next.provider = this.cloneProvider(this.snapshot.settings.provider);
    next.provider.keyConfigured = this.snapshot.settings.provider.keyConfigured;
    next.providerProfiles = cloneProviderProfiles(this.snapshot.settings.providerProfiles);
    next.selectedProviderId = this.snapshot.settings.selectedProviderId;
    this.snapshot.settings = next;
    const outcome = this.persistSettingsOutcome(next);
    if (!outcome.ok) {
      this.snapshot.settings = previous;
      this.lastPersistError = outcome.error;
      this.snapshot.failure = outcome.error;
      this.emit();
      throw new Error(outcome.error);
    }
    let notice = '设置已保存';
    if (next.backgroundKeepAlive) {
      notice += '；HarmonyOS 宿主未实现后台常驻，系统仍可能回收运行时。';
    }
    if (next.permission !== previousPermission && this.workerReady) {
      try {
        await this.updatePermissionPreset(next.permission);
        notice += '；新会话权限默认值已同步给 Worker。';
      } catch (error) {
        notice += `；Worker 权限默认值未同步：${this.clean(errorText(error as Error))}`;
      }
    }
    this.lastPersistError = '';
    this.snapshot.failure = '';
    this.snapshot.notice = notice;
    this.emit();
  }

  /**
   * Switch the current Worker session's model route through `session/selectModel`.
   * The caller's selection is only a request: success is reported after the
   * `session/projections` readback agrees, never from the in-memory click.
   */
  async selectModel(selection: SessionModelSelection): Promise<void> {
    const session = this.activeSession();
    if (session === null || session.workerSessionId.length === 0) {
      throw this.controlError(this.uiCopy('当前会话还没有 Worker 会话，无法切换模型。'));
    }
    const resolved = resolveModelSelection(
      this.snapshot.modelOptions,
      this.snapshot.modelSelection,
      selection.provider,
      selection.model,
      selection.effort
    );
    if (resolved === null) {
      throw this.controlError(this.uiCopy('模型目录里没有这个模型或推理强度，请刷新后重试。'));
    }
    const request: Record<string, Object> = {};
    request['sessionId'] = session.workerSessionId;
    request['provider'] = resolved.provider;
    request['model'] = resolved.model;
    if (resolved.effort.length > 0) {
      request['reasoningEffort'] = resolved.effort;
    }
    const args = new RequestWrapper(request);
    try {
      await this.pageBridge.call('session/selectModel', args, 15000);
    } catch (error) {
      throw this.controlError(this.uiFill('模型没有切换成功：{0}', [this.clean(errorText(error as Error))]));
    }
    const modelConfirmed = await this.refreshSessionControls();
    if (!modelConfirmed) {
      throw this.controlError(this.uiCopy('模型切换已提交，但会话状态没有刷新确认。'));
    }
    if (!this.selectionMatches(resolved)) {
      throw this.controlError(this.uiCopy('模型切换没有被会话确认。'));
    }
    this.snapshot.failure = '';
    this.snapshot.notice = this.uiFill('已切换模型：{0} · {1}', [resolved.provider, resolved.model]);
    this.emit();
  }

  /**
   * Apply a permission to the current Worker session exactly like Android:
   * `commands/execute` with `/permission <id>`, then confirm through projections.
   * This never writes the new-session permission default.
   */
  async selectPermission(id: string): Promise<void> {
    const session = this.activeSession();
    if (session === null || session.workerSessionId.length === 0) {
      throw this.controlError(this.uiCopy('当前会话还没有 Worker 会话，无法切换权限。'));
    }
    if (this.permissionOption(id) === null) {
      throw this.controlError(this.uiCopy('权限目录里没有这个权限模式，请刷新后重试。'));
    }
    const attachments: Object[] = [];
    const args: Record<string, Object> = {};
    args['agentId'] = session.workerSessionId;
    args['line'] = `/permission ${id}`;
    args['submittedAttachments'] = attachments;
    try {
      const value = await this.pageBridge.call('commands/execute', args, 15000);
      let root = asRecord(value);
      const unwrapped = this.remoteValue(root);
      if (unwrapped !== null) {
        root = unwrapped;
      }
      const result = asRecord(root === null ? null : root['result']);
      const kind = jsonString(result, 'kind');
      if (kind.length === 0 || kind === 'error') {
        throw new Error(jsonString(result, 'text', '命令没有执行成功'));
      }
    } catch (error) {
      throw this.controlError(this.uiFill('权限没有切换成功：{0}', [this.clean(errorText(error as Error))]));
    }
    const permissionConfirmed = await this.refreshSessionControls();
    if (!permissionConfirmed) {
      throw this.controlError(this.uiCopy('权限命令已提交，但会话状态没有刷新确认。'));
    }
    if (this.snapshot.currentPermission !== id) {
      throw this.controlError(this.uiCopy('权限命令没有被会话确认。'));
    }
    const option = this.permissionOption(id);
    const title = option === null ? id : option.title;
    this.snapshot.failure = '';
    this.snapshot.notice = this.uiFill('本会话权限已切换为：{0}', [title]);
    this.emit();
  }

  // -------------------------------------------------------------- engine

  async startEngine(): Promise<void> {
    if (this.nativeRunning) {
      if (this.snapshot.runtimeUrl.length > 0) {
        this.workerReady = false;
        this.snapshot.engine = EnginePhase.Booting;
        this.snapshot.engineText = this.uiCopy('正在重新加载本地运行时');
        this.proxy.cancelPending();
        this.closeAllStreams();
        this.pendingTurns = 0;
        this.clearArtifactsMeasurement();
        this.clearVisiblePending();
        this.clearQueueState();
        this.snapshot.running = false;
        this.snapshot.stopping = false;
        this.resetSessionControls();
        this.emit();
        this.pageBridge.reloadRuntime();
      } else {
        await this.startNativeRuntime();
      }
      return;
    }
    await this.startNativeRuntime();
  }

  async stopEngine(): Promise<void> {
    this.proxy.cancelPending();
    this.closeAllStreams();
    this.workerReady = false;
    this.eventsReady = false;
    this.pendingTurns = 0;
    this.clearArtifactsMeasurement();
    this.clearVisiblePending();
    this.clearQueueState();
    this.snapshot.running = false;
    this.snapshot.stopping = false;
    if (this.nativeRunning) {
      try {
        native.stop();
      } catch (error) {
        this.snapshot.failure = this.uiCopy('停止本地运行时失败');
      }
      this.nativeRunning = false;
    }
    this.runtimeToken = '';
    this.snapshot.runtimeUrl = '';
    this.snapshot.engine = EnginePhase.Stopped;
    this.snapshot.engineText = this.uiCopy('本地运行时已停止');
    this.resetSessionControls();
    this.persistNow();
    this.emit();
  }

  // Debug-build-only QA hook: terminate the ArkWeb renderer through the public
  // controller so the real onRenderExited path (not a synthesized failure) is
  // exercised. A release build and an unattached bridge reject; the actual
  // renderer exit is observed by the WebView callback, never marked here.
  async simulateRendererExit(): Promise<void> {
    if (!this.snapshot.debuggable) {
      throw new Error('模拟运行视图退出仅在调试版本可用');
    }
    if (!this.pageBridge.isAttached()) {
      throw new Error('本地运行时页面桥尚未附加');
    }
    if (!this.pageBridge.terminateRenderer()) {
      throw new Error('系统拒绝终止运行视图进程');
    }
  }

  /** Load the registered slash-command catalog for the current Worker session. */
  async refreshCommands(): Promise<void> {
    if (!this.workerReady) {
      this.snapshot.commands = [];
      this.snapshot.commandError = '本地运行时还没就绪；指令目录尚未读取。';
      this.emit();
      return;
    }
    let session = this.activeSession();
    if (session === null) {
      session = this.createLocalSession('新会话');
    }
    if (!await this.ensureWorkerSession(session)) {
      this.snapshot.commandError = this.uiCopy('Worker 会话尚未建立；草稿已保留。');
      this.emit();
      return;
    }
    const workerSessionId = session.workerSessionId;
    this.controlsGeneration = this.controlsGeneration + 1;
    await this.loadComposerCommands(workerSessionId, this.controlsGeneration);
  }

  async refresh(): Promise<void> {
    if (this.snapshot.page === Page.Chat) {
      await this.refreshSessionControls();
      return;
    }
    await this.loadForPage();
  }

  /**
   * Reads the in-place `@` candidates the way Android does: workspace-relative
   * file paths and the titles of the other non-archived chats, both local. Files
   * come from the verified Worker workspace through the existing `$listFiles`
   * command (recursive here, because that command reads one directory). A read
   * failure is a visible Failed phase, never an empty Ready.
   */
  async refreshReferences(): Promise<void> {
    if (!await this.ensureRpcReady(15000)) {
      this.snapshot.referencesPhase = LoadPhase.Failed;
      this.snapshot.referencesError = this.uiCopy('本地运行时尚未就绪，无法读取引用候选');
      this.emit();
      return;
    }
    this.snapshot.referencesPhase = LoadPhase.Loading;
    this.snapshot.referencesError = '';
    this.emit();
    // Titles are durable local records, so they stay available even when the
    // workspace walk fails; the failed phase still makes that failure visible.
    const sessions: string[] = this.referenceSessionsNow();
    try {
      const files: string[] = await this.loadReferenceFiles();
      this.snapshot.referenceFiles = files;
      this.snapshot.referenceSessions = sessions;
      this.snapshot.referencesPhase = LoadPhase.Ready;
      this.snapshot.referencesError = '';
    } catch (error) {
      this.snapshot.referenceSessions = sessions;
      this.snapshot.referencesPhase = LoadPhase.Failed;
      this.snapshot.referencesError =
        this.uiFill('引用候选读取失败：{0}', [this.clean(errorText(error as Error))]);
    }
    this.emit();
  }

  private referenceSessionsNow(): string[] {
    const facts: ComposerReferenceSessionFact[] = [];
    for (let index: number = 0; index < this.snapshot.sessions.length; index++) {
      const record: SessionRecord = this.snapshot.sessions[index];
      const fact = new ComposerReferenceSessionFact();
      fact.id = record.id;
      fact.title = record.title;
      fact.archived = record.archived;
      facts.push(fact);
    }
    return referenceSessionTitles(facts, this.snapshot.activeSessionId);
  }

  /**
   * Breadth-first walk of `/dsh/workspace` with the existing `$listFiles`.
   * Stops at 200 regular files like Android; a walk that hits the directory
   * safety bound before it can decide is a visible failure, not a partial
   * Ready list.
   */
  private async loadReferenceFiles(): Promise<string[]> {
    const root: string = '/dsh/workspace';
    const files: string[] = [];
    const pending: string[] = [root];
    let directories: number = 0;
    while (pending.length > 0 && files.length < REFERENCE_FILE_LIMIT) {
      if (directories >= REFERENCE_DIRECTORY_LIMIT) {
        throw new Error(`工作区目录超过 ${REFERENCE_DIRECTORY_LIMIT} 个，引用候选未完整读取`);
      }
      const directory: string = pending[0];
      pending.splice(0, 1);
      directories++;
      const value = await this.pageBridge.callListFiles(directory);
      const rows = asArray(value);
      for (let index: number = 0; index < rows.length && files.length < REFERENCE_FILE_LIMIT; index++) {
        const row = asRecord(rows[index]);
        if (row === null) {
          continue;
        }
        const path: string = jsonString(row, 'path', '');
        if (path.length === 0) {
          continue;
        }
        if (jsonBool(row, 'directory', false)) {
          pending.push(path);
        } else {
          const relative: string = referenceRelativePath(root, path);
          if (relative.length > 0) {
            files.push(relative);
          }
        }
      }
    }
    files.sort((left: string, right: string): number => {
      if (left === right) {
        return 0;
      }
      return left < right ? -1 : 1;
    });
    return files;
  }

  // --------------------------------------------------------------- files

  /**
   * Opens a Markdown file/sandbox/dsh-resource link. Identity is resolved with
   * Android's session/safe-root policy first; an unknown session or traversal
   * is a visible refusal, never a fallback to the active workspace.
   */
  async openResource(source: string): Promise<void> {
    const resolved = resolveMarkdownResource(source, this.resourceContext());
    if (resolved.kind === ResourceKind.Refused) {
      this.snapshot.failure = `无法打开资源：${refusalText(resolved.reason)}`;
      this.emit();
      return;
    }
    if (resolved.kind === ResourceKind.Remote) {
      this.snapshot.previewPath = resolved.target;
      this.snapshot.previewText = '';
      this.pushNavigationFrame(navPreviewFrame(resolved.target, ''));
      this.emit();
      return;
    }
    await this.openFile(resolved.target);
  }

  /**
   * Loads Markdown image bytes for one component. Remote sources use plain
   * NetworkKit HTTP (no proxy/cookies/auth, bounded 8 MiB, manual 3-hop
   * validated redirects); local sources use the private Worker byte snapshot
   * commands. The returned ArrayBuffer is owned by the calling component.
   */
  async loadImage(source: string, control?: ImageLoadControl): Promise<ImageBytes> {
    control?.assertActive();
    const resolved = resolveMarkdownResource(source, this.resourceContext());
    if (resolved.kind === ResourceKind.Refused) {
      throw new Error(refusalText(resolved.reason));
    }
    if (resolved.kind === ResourceKind.Remote) {
      const image = new ImageBytes();
      image.data = await this.fetchRemoteImage(resolved.target, control);
      image.mime = mimeForPath(resolved.target);
      return image;
    }
    return await this.readWorkerImage(resolved.target, mimeForPath(resolved.target), control);
  }

  private resourceContext(): ResourceContext {
    const context = new ResourceContext();
    const session = this.activeSession();
    context.currentWorkerSessionId = session === null ? '' : session.workerSessionId;
    const known: string[] = [];
    for (let index: number = 0; index < this.snapshot.sessions.length; index++) {
      const workerId: string = this.snapshot.sessions[index].workerSessionId;
      if (workerId.length > 0 && known.indexOf(workerId) < 0) {
        known.push(workerId);
      }
    }
    context.knownWorkerSessionIds = known;
    context.hasVerifiedWorkspace = this.workerReady;
    return context;
  }

  private async readWorkerImage(path: string, mime: string, control?: ImageLoadControl): Promise<ImageBytes> {
    if (!await this.ensureRpcReady(15000)) {
      throw new Error('本地运行时尚未就绪，无法读取图片');
    }
    control?.assertActive();
    const opened = await this.pageBridge.callOpenBinaryRead(path);
    if (opened.size <= 0) {
      try {
        await this.pageBridge.callCloseBinaryRead(opened.id);
      } catch (closeError) {
      }
      throw new Error('图片文件为空');
    }
    const parts: Uint8Array[] = [];
    let offset: number = 0;
    try {
      control?.assertActive();
      while (offset < opened.size) {
        control?.assertActive();
        const chunk = await this.pageBridge.callReadBinaryChunk(opened.id, offset);
        control?.assertActive();
        const bytes: Uint8Array = decodeBase64(chunk.base64);
        if (bytes.length === 0) {
          throw new Error('图片读取返回空块');
        }
        parts.push(bytes);
        offset += bytes.length;
        if (offset > opened.size) {
          throw new Error('图片读取超出快照大小');
        }
      }
    } finally {
      try {
        await this.pageBridge.callCloseBinaryRead(opened.id);
      } catch (closeError) {
      }
    }
    const image = new ImageBytes();
    image.data = exactArrayBuffer(concatBytes(parts, opened.size));
    image.mime = opened.mime.length > 0 ? opened.mime : mime;
    return image;
  }

  private async fetchRemoteImage(initial: string, control?: ImageLoadControl): Promise<ArrayBuffer> {
    let current: string = initial;
    for (let redirect: number = 0; redirect <= MAX_REMOTE_REDIRECTS; redirect++) {
      if (!isValidRemoteUri(current)) {
        throw new Error('远程图片地址不安全');
      }
      control?.assertActive();
      const request = http.createHttp();
      const unsubscribe = control?.subscribe((): void => {
        try { request.destroy(); } catch (error) {}
      });
      try {
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false,
          connectTimeout: 5000,
          readTimeout: 8000,
          maxRedirects: 0,
          maxLimit: MAX_REMOTE_IMAGE_BYTES + 1
        };
        const response: http.HttpResponse = await request.request(current, options);
        control?.assertActive();
        const status: number = response.responseCode as number;
        if (status >= 300 && status <= 399) {
          if (redirect >= MAX_REMOTE_REDIRECTS) {
            throw new Error('远程图片重定向超过 3 次');
          }
          const location: string = this.responseLocation(response);
          const next: string = nextRemoteRedirect(current, location);
          if (next.length === 0) {
            throw new Error('远程图片重定向目标不安全');
          }
          current = next;
          continue;
        }
        if (status < 200 || status > 299) {
          throw new Error('远程图片请求返回 HTTP ' + status);
        }
        const body: ArrayBuffer = response.result as ArrayBuffer;
        if (body === undefined || body === null || body.byteLength === 0) {
          throw new Error('远程图片响应为空');
        }
        if (body.byteLength > MAX_REMOTE_IMAGE_BYTES) {
          throw new Error('远程图片超过 8 MiB');
        }
        return body;
      } finally {
        if (unsubscribe !== undefined) unsubscribe();
        request.destroy();
      }
    }
    throw new Error('远程图片重定向超过 3 次');
  }

  private responseLocation(response: http.HttpResponse): string {
    const header = response.header as Record<string, Object>;
    if (header === null || header === undefined) {
      return '';
    }
    const lower: Object | undefined = header['location'];
    if (typeof lower === 'string') {
      return lower as string;
    }
    const upper: Object | undefined = header['Location'];
    if (typeof upper === 'string') {
      return upper as string;
    }
    return '';
  }

  async openFile(path: string): Promise<void> {
    // Preview binaries stay binary: never ask the Worker to UTF-8 decode an
    // image file. PreviewView renders it through the typed image loader.
    if (isImagePath(path) || path.startsWith('http://') || path.startsWith('https://')) {
      this.snapshot.previewPath = path;
      this.snapshot.previewText = '';
      this.snapshot.filesPhase = LoadPhase.Ready;
      const directory: string = this.snapshot.page === Page.Files ? this.snapshot.filePath : '';
      this.pushNavigationFrame(navPreviewFrame(path, directory));
      this.emit();
      return;
    }
    if (!await this.ensureRpcReady(15000)) {
      this.snapshot.filesPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法读取文件');
      this.emit();
      return;
    }
    try {
      const value = await this.pageBridge.callListFiles(path);
      const files = this.filesFrom(value);
      this.snapshot.files = files;
      this.snapshot.filesPhase = LoadPhase.Ready;
      this.pushNavigationFrame(navFilesFrame(path));
      this.emit();
    } catch (listError) {
      try {
        const value = await this.pageBridge.callReadFile(path);
        const row = asRecord(value);
        const directory = this.snapshot.page === Page.Files ? this.snapshot.filePath : '';
        this.snapshot.previewText = bounded(jsonString(row, 'text', ''), 1024 * 1024);
        this.pushNavigationFrame(navPreviewFrame(path, directory));
        this.emit();
      } catch (readError) {
        this.snapshot.filesPhase = LoadPhase.Failed;
        this.snapshot.failure = this.uiFill('无法读取文件：{0}', [this.clean(errorText(readError as Error))]);
        this.emit();
      }
    }
  }

  async pickFiles(images: boolean): Promise<void> {
    if (this.context === null) {
      this.snapshot.failure = this.uiCopy('宿主上下文尚未初始化');
      this.emit();
      return;
    }
    let uris: string[] = [];
    try {
      uris = images ? await this.pickImages() : await this.pickDocuments();
    } catch (error) {
      this.snapshot.notice = this.uiCopy('没有选择附件。');
      this.emit();
      return;
    }
    if (uris.length === 0) {
      this.snapshot.notice = this.uiCopy('没有选择附件。');
      this.emit();
      return;
    }
    if (!await this.ensureRpcReady(15000)) {
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪；附件没有写入 Worker 文件系统');
      this.emit();
      return;
    }
    let imported = 0;
    let firstError = '';
    for (let index = 0; index < uris.length; index++) {
      const uri = uris[index];
      try {
        const path = await this.importPickedFile(uri);
        this.snapshot.attachmentPaths.push(path);
        imported++;
      } catch (error) {
        if (firstError.length === 0) {
          firstError = this.clean(errorText(error as Error));
        }
      }
    }
    if (imported > 0) {
      this.snapshot.notice = this.uiFill('{0} 个附件已写入 Worker 工作区；发送时才会引用。', [imported.toString()]);
    }
    if (firstError.length > 0) {
      this.snapshot.failure = this.uiFill('部分附件未导入：{0}', [firstError]);
    }
    this.persistNow();
    this.emit();
  }

  removeAttachment(path: string): void {
    const next: string[] = [];
    for (let index = 0; index < this.snapshot.attachmentPaths.length; index++) {
      if (this.snapshot.attachmentPaths[index] !== path) {
        next.push(this.snapshot.attachmentPaths[index]);
      }
    }
    this.snapshot.attachmentPaths = next;
    this.persistNow();
    this.emit();
  }

  async exportSession(): Promise<void> {
    if (this.context === null) {
      this.snapshot.failure = this.uiCopy('宿主上下文尚未初始化');
      this.emit();
      return;
    }
    if (this.snapshot.rows.length === 0) {
      this.snapshot.notice = this.uiCopy('当前会话没有可导出的内容');
      this.emit();
      return;
    }
    const text = this.transcriptMarkdown();
    const name = `${this.safeName(this.snapshot.title)}-${Date.now()}.md`;
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options: picker.DocumentSaveOptions = { newFileNames: [name] };
      const uris = await documentPicker.save(options);
      if (uris.length === 0) {
        this.snapshot.notice = this.uiCopy('没有选择导出位置');
        this.emit();
        return;
      }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, toArrayBuffer(encodeUtf8(text)));
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      this.snapshot.notice = this.uiCopy('会话已导出到所选位置。');
      this.emit();
    } catch (error) {
      this.snapshot.failure = this.uiFill('导出失败：{0}', [this.clean(errorText(error as Error))]);
      this.emit();
    }
  }

  // ------------------------------------------------------------- command

  async runCommand(command: string): Promise<void> {
    const text = command.trim();
    if (text.length === 0) {
      return;
    }
    this.snapshot.command = text;
    this.snapshot.commandOutput = this.uiCopy('正在运行…');
    this.emit();
    if (!await this.ensureRpcReady(15000)) {
      this.snapshot.commandOutput = this.uiCopy('命令未运行：本地运行时尚未就绪');
      this.emit();
      return;
    }
    const cwd = this.snapshot.filePath.startsWith('/dsh/') ? this.snapshot.filePath : '/dsh/workspace';
    try {
      const value = await this.pageBridge.callCommand(text, cwd);
      const row = asRecord(value);
      const exitCode = jsonNumber(row, 'exitCode', -1);
      let output = '';
      const stdout = jsonString(row, 'stdout', '');
      const stderr = jsonString(row, 'stderr', '');
      if (stdout.length > 0) {
        output += stdout;
      }
      if (stderr.length > 0) {
        output += `${output.length > 0 ? '\n' : ''}[stderr]\n${stderr}`;
      }
      output = bounded(output, 256 * 1024);
      this.snapshot.commandOutput = `exit ${exitCode}\n${output}`;
    } catch (error) {
      this.snapshot.commandOutput = this.uiFill('命令未运行：{0}', [this.clean(errorText(error as Error))]);
    }
    this.emit();
  }

  // --------------------------------------------------------- interactive

  async answerRequest(id: string, answer: string): Promise<void> {
    const meta = this.pendingMeta.get(id);
    if (meta === undefined) {
      this.snapshot.notice = this.uiCopy('这个待处理请求已经不存在');
      this.emit();
      return;
    }
    if (this.answeringRequests.has(id)) {
      return;
    }
    this.answeringRequests.set(id, true);
    try {
      let outcome: Object;
      if (meta.eventKind === 'user-questions/request') {
        outcome = this.questionOutcome(meta, answer) as Object;
      } else {
        const allowed = answer === 'allow' || answer === 'approved' ||
          answer.includes('允许') || answer.toLowerCase().includes('allow');
        const permission: PermissionOutcome = { kind: 'result', value: allowed ? 'allowed-once' : 'rejected' };
        outcome = permission as Object;
      }
      const args: EventAnswerArgs = { clientId: meta.clientId, eventId: meta.id, outcome: outcome };
      try {
        await this.pageBridge.call('$events/result', args as Object, 15000);
        this.removePending(id);
        this.snapshot.notice = this.uiCopy('已提交回答。');
        this.snapshot.failure = '';
      } catch (error) {
        this.snapshot.failure = this.uiFill('回答未送达：{0}', [this.clean(errorText(error as Error))]);
      }
    } finally {
      this.answeringRequests.delete(id);
    }
    this.emit();
  }

  /**
   * Android dismiss only hides the card. The responder and event stay live, so
   * this method never sends `$events/result` and never mutates the answer.
   */
  async dismissPending(id: string): Promise<void> {
    this.hidePending(id);
    this.emit();
  }

  // -------------------------------------------------------- generic items

  async setItemEnabled(id: string, enabled: boolean): Promise<void> {
    const meta = this.itemMeta.get(id);
    if (meta !== undefined && meta.kind === 'plugin') {
      const args: PluginToggleArgs = { entryId: meta.field, enabled: enabled };
      try {
        const value = await this.pageBridge.call('phone/pluginSetEnabled', args as Object, 10000);
        const root = asRecord(value);
        if (root === null || root['ok'] === undefined) {
          throw new Error('pluginSetEnabled 返回了无法识别的结果');
        }
        if (!jsonBool(root, 'ok', false)) {
          const reason = jsonString(root, 'reason', jsonString(root, 'code', '插件状态未修改'));
          throw new Error(reason);
        }
        const view = asRecord(root['value']);
        const changed = jsonBool(view, 'changed', false);
        const enabledValue = jsonBool(view, 'enabled', enabled);
        const restartRequired = jsonBool(view, 'restartRequired', false);
        this.snapshot.failure = '';
        if (!changed) {
          this.snapshot.notice = this.uiFill('插件已是{0}状态，未改动。', [this.uiCopy(enabledValue ? '启用' : '停用')]);
        } else if (restartRequired) {
          this.snapshot.notice = this.uiFill('插件已{0}；重启 Worker 后生效。', [this.uiCopy(enabledValue ? '启用' : '停用')]);
        } else {
          this.snapshot.notice = this.uiFill('插件已{0}。', [this.uiCopy(enabledValue ? '启用' : '停用')]);
        }
        this.emit();
        await this.loadForPage();
      } catch (error) {
        this.snapshot.notice = '';
        this.snapshot.failure = this.uiFill('插件状态未修改：{0}', [this.clean(errorText(error as Error))]);
        this.emit();
        throw error as Error;
      }
      return;
    }
    if (meta !== undefined && meta.kind === 'config' && meta.valueType === 'boolean') {
      await this.saveItem(id, enabled ? 'true' : 'false');
      return;
    }
    this.snapshot.notice = this.uiCopy('这个条目没有可用的启用/停用宿主实现。');
    this.emit();
  }

  async saveItem(id: string, value: string): Promise<void> {
    const meta = this.itemMeta.get(id);
    if (meta === undefined) {
      if (id === 'automation:new' || id === 'automation') {
        const createMeta = new ItemMeta();
        createMeta.kind = 'automation';
        await this.saveAutomation(createMeta, value);
        return;
      }
      if (id.startsWith('session:')) {
        await this.openSession(id.substring(8));
        return;
      }
      const message = '这个条目没有可写入的宿主实现。';
      this.snapshot.notice = '';
      this.snapshot.failure = message;
      this.emit();
      throw new Error(message);
    }
    if (meta.kind === 'config') {
      await this.saveConfigField(meta, value);
      return;
    }
    if (meta.kind === 'permission') {
      const mode = value.trim().length > 0 && value !== id ? value : meta.field;
      try {
        await this.updatePermissionPreset(mode);
        this.snapshot.notice = this.uiCopy('新会话权限默认值已同步给 Worker。');
        await this.loadForPage();
      } catch (error) {
        this.snapshot.failure = this.uiFill('权限设置未保存：{0}', [this.clean(errorText(error as Error))]);
        this.emit();
      }
      return;
    }
    if (meta.kind === 'automation') {
      await this.saveAutomation(meta, value);
      return;
    }
    if (meta.kind === 'preset') {
      await this.activatePreset(meta, value);
      return;
    }
    if (meta.kind === 'settingsDocument') {
      await this.saveSettingsDocument(meta, value);
      return;
    }
    if (meta.kind === 'fontSize') {
      const size = Number(value);
      if (Number.isFinite(size) && size >= 12 && size <= 32) {
        const previousSize = this.snapshot.settings.fontSize;
        this.snapshot.settings.fontSize = size;
        const outcome = this.persistSettingsOutcome(this.snapshot.settings);
        if (!outcome.ok) {
          this.snapshot.settings.fontSize = previousSize;
          this.lastPersistError = outcome.error;
          this.snapshot.failure = outcome.error;
          this.emit();
          throw new Error(outcome.error);
        }
        this.lastPersistError = '';
        this.snapshot.failure = '';
        this.snapshot.notice = this.uiCopy('字号已保存');
        await this.loadForPage();
      }
      return;
    }
    if (meta.kind === 'shortcut') {
      const message = '快捷键设置是本地界面状态；当前版本未提供可写入的宿主字段。';
      this.snapshot.notice = '';
      this.snapshot.failure = message;
      this.emit();
      throw new Error(message);
    }
    const message = '这个条目没有可写入的宿主实现。';
    this.snapshot.notice = '';
    this.snapshot.failure = message;
    this.emit();
    throw new Error(message);
  }

  async deleteItem(id: string): Promise<void> {
    const meta = this.itemMeta.get(id);
    if (meta !== undefined && meta.kind === 'automation') {
      const request: Record<string, Object> = { id: meta.field, action: 'delete' };
      try {
        const result = this.remoteValue(asRecord(
          await this.pageBridge.call('schedule/edit', new RequestWrapper(request), 15000)));
        if (result === null || result['deleted'] !== true) {
          throw new Error(this.uiCopy('定时任务已不存在，请刷新后重试'));
        }
        this.snapshot.notice = this.uiCopy('定时任务已删除。');
        await this.loadForPage();
      } catch (error) {
        this.snapshot.failure = this.uiFill('删除失败：{0}', [this.clean(errorText(error as Error))]);
        this.emit();
      }
      return;
    }
    if (id.startsWith('session:')) {
      await this.deleteSession(id.substring(8));
      return;
    }
    if (id.startsWith('folder:')) {
      await this.deleteFolder(id.substring(7));
      return;
    }
    if (id.startsWith('attachment:')) {
      this.removeAttachment(id.substring(11));
      return;
    }
    if (id.startsWith('file:')) {
      await this.deleteWorkerFile(id.substring(5));
      return;
    }
    if (meta !== undefined && meta.kind === 'plugin') {
      this.snapshot.notice = '';
      this.snapshot.failure = this.uiCopy('已安装插件由 DSH 安装层管理；本宿主不提供卸载写入。');
      this.emit();
      throw new Error(this.snapshot.failure);
    } else if (meta !== undefined && meta.kind === 'preset') {
      this.snapshot.notice = '';
      this.snapshot.failure = this.uiCopy('Agent 预设由 Worker 管理；当前 RPC 只提供读取。');
      this.emit();
      throw new Error(this.snapshot.failure);
    }
    const message = '这个条目没有可用的删除宿主实现。';
    this.snapshot.notice = '';
    this.snapshot.failure = message;
    this.emit();
    throw new Error(message);
  }

  // ------------------------------------------------------ page bridge events

  onBridgeStreamEvent(streamId: string, value: Object): void {
    if (streamId === 'events') {
      this.handleEventsValue(value);
      return;
    }
    if (streamId !== this.activeStreamId) {
      return;
    }
    this.followSeen.add(streamId);
    const waiter = this.followWaiters.get(streamId);
    if (waiter !== undefined) {
      waiter();
    }
    this.handleFollowValue(value);
  }

  onBridgeStreamEnd(streamId: string, error: string): void {
    if (streamId === 'events') {
      this.eventsReady = false;
      if (this.eventsWaiter !== null) {
        this.eventsWaiter();
        this.eventsWaiter = null;
      }
      if (error.length > 0 && this.snapshot.engine === EnginePhase.Ready && !this.disposed) {
        this.snapshot.notice = this.uiFill('实时审批事件流已断开：{0}', [this.clean(error)]);
        this.emit();
      }
      return;
    }
    if (streamId !== this.activeStreamId) {
      return;
    }
    const waiter = this.followWaiters.get(streamId);
    if (waiter !== undefined) {
      waiter();
    }
    const wasByUs = this.streamClosedByUs;
    this.activeStreamId = '';
    this.activeStreamSessionId = '';
    this.streamClosedByUs = false;
    this.followSeen.delete(streamId);
    if (!wasByUs && this.pendingTurns > 0) {
      this.pendingTurns = 0;
      this.endArtifacts();
      this.snapshot.running = false;
      this.snapshot.stopping = false;
      this.clearQueueState();
      if (error.length > 0 && error !== 'cancelled') {
        this.snapshot.failure = this.uiFill('会话事件流中断：{0}', [this.clean(error)]);
        this.appendRow(this.errorRow(this.uiCopy('会话事件流中断'), this.clean(error)));
      }
      this.flushStreamText('', false);
      this.persistNow();
      this.emit();
    }
  }

  // ---------------------------------------------------- state helpers

  private controlError(message: string): Error {
    this.snapshot.failure = message;
    this.emit();
    return new Error(message);
  }

  private selectionMatches(selection: SessionModelSelection): boolean {
    const current = this.snapshot.modelSelection;
    if (current.provider !== selection.provider || current.model !== selection.model) {
      return false;
    }
    return selection.effort.length === 0 || current.effort === selection.effort;
  }

  private permissionOption(id: string): SessionPermissionOption | null {
    for (let index = 0; index < this.snapshot.permissionOptions.length; index++) {
      if (this.snapshot.permissionOptions[index].id === id) {
        return this.snapshot.permissionOptions[index];
      }
    }
    return null;
  }

  private resetSessionControls(): void {
    this.controlsGeneration = this.controlsGeneration + 1;
    if (this.projectionFailure.length > 0 && this.snapshot.failure === this.projectionFailure) {
      this.snapshot.failure = '';
    }
    this.snapshot.modelOptions = [];
    this.snapshot.modelSelection = new SessionModelSelection();
    this.snapshot.modelError = '';
    this.snapshot.permissionOptions = [];
    this.snapshot.currentPermission = '';
    this.snapshot.permissionError = '';
    this.snapshot.commands = [];
    this.snapshot.commandError = '';
    this.snapshot.lastCommandId = '';
    this.projectionFailure = '';
  }

  private refreshControlsQuietly(): void {
    this.refreshSessionControls().catch((error: Error) => {
      this.snapshot.modelError = this.uiFill('模型目录读取失败：{0}', [this.clean(errorText(error))]);
      this.emit();
    });
  }

  private controlsStillCurrent(generation: number, workerSessionId: string): boolean {
    if (generation !== this.controlsGeneration) {
      return false;
    }
    const session = this.activeSession();
    const currentWorker = session === null ? '' : session.workerSessionId;
    return currentWorker === workerSessionId;
  }

  private queueStillCurrent(generation: number, workerSessionId: string): boolean {
    if (generation !== this.queueGeneration) {
      return false;
    }
    const session = this.activeSession();
    return session !== null && session.workerSessionId === workerSessionId;
  }

  private queueFailureText(message: string): string {
    const clean = this.clean(message);
    if (clean.includes('migration-required')) {
      return this.uiCopy('队列需要迁移，暂时无法读取。');
    }
    return this.uiFill('队列状态读取失败：{0}', [clean]);
  }

  private applyQueueRead(workerSessionId: string, generation: number, items: QueueItem[]): void {
    if (!this.queueStillCurrent(generation, workerSessionId)) {
      return;
    }
    const merged = mergeDurableQueue(this.snapshot.queueItems, items);
    this.snapshot.queueItems = merged;
    this.snapshot.queueFailure = '';
    if (merged !== null) {
      this.snapshot.localQueueItems = retireLocalQueueByDurable(this.snapshot.localQueueItems, merged);
    }
  }

  private applyQueueResult(workerSessionId: string, generation: number,
    result: QueueProjectionResult): void {
    if (!this.queueStillCurrent(generation, workerSessionId)) {
      return;
    }
    if (result.items === null) {
      this.snapshot.queueItems = null;
      this.snapshot.queueFailure = this.queueFailureText(result.failure);
      return;
    }
    this.applyQueueRead(workerSessionId, generation, result.items);
  }

  private async fetchQueueProjection(workerSessionId: string): Promise<QueueProjectionResult> {
    const result = new QueueProjectionResult();
    if (workerSessionId.length === 0) {
      result.items = [];
      return result;
    }
    const request: Record<string, Object> = {};
    request['sessionId'] = workerSessionId;
    try {
      const value = await this.pageBridge.call('session/projections',
        new RequestWrapper(request), 5000);
      return parseQueueProjection(workerSessionId, this.catalogRoot(value));
    } catch (error) {
      result.items = null;
      result.failure = this.clean(errorText(error as Error));
      return result;
    }
  }

  private async refreshQueueFor(workerSessionId: string): Promise<void> {
    const generation = this.queueGeneration;
    if (workerSessionId.length === 0) {
      if (this.queueStillCurrent(generation, workerSessionId)) {
        this.snapshot.queueItems = [];
        this.snapshot.queueFailure = '';
        this.snapshot.localQueueItems = [];
      }
      return;
    }
    const result = await this.fetchQueueProjection(workerSessionId);
    this.applyQueueResult(workerSessionId, generation, result);
  }

  /**
   * Event-driven refresh only: session open, prompt ack, user admission and
   * real turn facts. Coalesce overlapping reads instead of polling.
   */
  private refreshQueueQuietly(): void {
    const session = this.activeSession();
    if (session === null) {
      return;
    }
    const workerSessionId = session.workerSessionId;
    if (workerSessionId.length === 0) {
      if (this.queueStillCurrent(this.queueGeneration, workerSessionId)) {
        this.snapshot.queueItems = [];
        this.snapshot.queueFailure = '';
        this.emit();
      }
      return;
    }
    if (this.queueRefreshInFlight) {
      this.queueRefreshQueued = true;
      return;
    }
    this.queueRefreshInFlight = true;
    const generation = this.queueGeneration;
    this.fetchQueueProjection(workerSessionId).then((result: QueueProjectionResult) => {
      this.queueRefreshInFlight = false;
      this.applyQueueResult(workerSessionId, generation, result);
      this.emit();
      if (this.queueRefreshQueued) {
        this.queueRefreshQueued = false;
        this.refreshQueueQuietly();
      }
    }, (error: Error) => {
      this.queueRefreshInFlight = false;
      if (this.queueStillCurrent(generation, workerSessionId)) {
        this.snapshot.queueItems = null;
        this.snapshot.queueFailure = this.uiFill('队列状态读取失败：{0}',
          [this.clean(errorText(error))]);
      }
      this.emit();
      if (this.queueRefreshQueued) {
        this.queueRefreshQueued = false;
        this.refreshQueueQuietly();
      }
    });
  }

  private clearQueueState(): void {
    this.queueGeneration = this.queueGeneration + 1;
    this.snapshot.queueItems = null;
    this.snapshot.localQueueItems = [];
    this.snapshot.queueFailure = '';
    this.pendingOwnQueueRequestIds = [];
  }

  private catalogRoot(value: Object): Record<string, Object> | null {
    const raw = asRecord(value);
    const unwrapped = this.remoteValue(raw);
    return unwrapped === null ? raw : unwrapped;
  }

  /**
   * `commands/list` takes `{agentId: workerSessionId}`. Catalog errors stay in
   * `snapshot.commandError`; an empty catalog never fabricates a command.
   */
  private async loadComposerCommands(workerSessionId: string, generation: number): Promise<void> {
    if (workerSessionId.length === 0) {
      this.snapshot.commands = [];
      this.snapshot.commandError = '';
      return;
    }
    const args: Record<string, Object> = {};
    args['agentId'] = workerSessionId;
    let root: Object | null = null;
    let failure = '';
    try {
      const value = await this.pageBridge.call('commands/list', args as Object, 5000);
      root = Array.isArray(value) ? value : this.catalogRoot(value);
      if (root === null) {
        failure = '没有返回指令目录';
      }
    } catch (error) {
      failure = this.clean(errorText(error as Error));
    }
    if (!this.controlsStillCurrent(generation, workerSessionId)) {
      return;
    }
    if (root === null) {
      this.snapshot.commands = [];
      this.snapshot.commandError = `指令目录读取失败：${failure}`;
    } else {
      this.snapshot.commands = commandsFromCatalog(root);
      this.snapshot.commandError = this.snapshot.commands.length === 0
        ? 'Worker 未发布可选指令；可刷新后重试。' : '';
    }
    this.emit();
  }

  /**
   * Hydrate only the composer's model and permission controls. Catalog reads are
   * independent: a failed projection keeps the last good selection, while a
   * failed catalog surfaces its own menu error. A selection is never written
   * from the request; `session/projections` is the sole authority.
   */
  private async refreshSessionControls(): Promise<boolean> {
    if (!this.workerReady) {
      return false;
    }
    const session = this.activeSession();
    const workerSessionId = session === null ? '' : session.workerSessionId;
    this.controlsGeneration = this.controlsGeneration + 1;
    const generation = this.controlsGeneration;

    let modelRoot: Record<string, Object> | null = null;
    let modelFailure = '';
    try {
      modelRoot = this.catalogRoot(await this.pageBridge.call('session/modelCatalog', EMPTY_ARGS, 5000));
      if (modelRoot === null) {
        modelFailure = '没有返回模型目录';
      }
    } catch (error) {
      modelFailure = this.clean(errorText(error as Error));
    }

    let permissionRoot: Record<string, Object> | null = null;
    let permissionFailure = '';
    try {
      permissionRoot = this.catalogRoot(await this.pageBridge.call('permissionPresets/catalog', EMPTY_ARGS, 5000));
      if (permissionRoot === null) {
        permissionFailure = '没有返回权限目录';
      }
    } catch (error) {
      permissionFailure = this.clean(errorText(error as Error));
    }

    if (!this.controlsStillCurrent(generation, workerSessionId)) {
      return false;
    }
    await this.loadComposerCommands(workerSessionId, generation);
    if (!this.controlsStillCurrent(generation, workerSessionId)) {
      return false;
    }
    if (modelRoot !== null) {
      this.snapshot.modelOptions = modelOptionsFromCatalog(modelRoot);
      const failures = asArray(modelRoot['failures']);
      const messages: string[] = [];
      for (let index = 0; index < failures.length; index++) {
        const failure = asRecord(failures[index]);
        const message = jsonString(failure, 'message', '');
        if (message.length > 0) messages.push(this.clean(message));
      }
      this.snapshot.modelError = messages.length > 0 ? messages.join('；')
        : (this.snapshot.modelOptions.length === 0 ? 'Worker 未发布可选模型；可刷新后重试。' : '');
    } else {
      this.snapshot.modelError = this.uiFill('模型目录读取失败：{0}', [modelFailure]);
    }
    if (permissionRoot !== null) {
      this.snapshot.permissionOptions = permissionOptionsFromCatalog(permissionRoot);
      this.snapshot.permissionError = '';
    } else {
      this.snapshot.permissionError = this.uiFill('权限目录读取失败：{0}', [permissionFailure]);
    }
    if (workerSessionId.length === 0) {
      this.snapshot.modelSelection = new SessionModelSelection();
      this.snapshot.currentPermission = '';
      this.snapshot.queueItems = [];
      this.snapshot.localQueueItems = [];
      this.snapshot.queueFailure = '';
      this.emit();
      return true;
    }
    this.emit();

    let projectionRoot: Record<string, Object> | null = null;
    let projectionFailure = '';
    const request: Record<string, Object> = {};
    request['sessionId'] = workerSessionId;
    try {
      projectionRoot = this.catalogRoot(await this.pageBridge.call(
        'session/projections', new RequestWrapper(request), 5000));
      if (projectionRoot === null) {
        projectionFailure = '没有返回会话投影';
      }
    } catch (error) {
      projectionFailure = this.clean(errorText(error as Error));
    }
    if (!this.controlsStillCurrent(generation, workerSessionId)) {
      return false;
    }
    if (projectionRoot === null) {
      this.projectionFailure = `会话状态读取失败：${projectionFailure}`;
      this.snapshot.failure = this.projectionFailure;
      this.snapshot.queueItems = null;
      this.snapshot.queueFailure = this.queueFailureText(projectionFailure);
      this.emit();
      return false;
    }
    const queue = parseQueueProjection(workerSessionId, projectionRoot);
    this.applyQueueResult(workerSessionId, this.queueGeneration, queue);
    this.snapshot.modelSelection = selectionFromProjections(projectionRoot);
    this.snapshot.currentPermission = permissionFromProjections(projectionRoot);
    // Metrics are a straight read of the Worker's own projection units. A unit
    // that is absent or malformed stays null so the footer hides that pill.
    const measured = parseSessionMetrics(projectionRoot);
    this.snapshot.sessionStats = measured.stats;
    this.snapshot.tokenUsage = measured.usage;
    this.snapshot.contextPressure = measured.pressure;
    this.snapshot.contextBreakdown = measured.breakdown;
    if (this.snapshot.failure === this.projectionFailure) {
      this.snapshot.failure = '';
    }
    this.projectionFailure = '';
    this.emit();
    return true;
  }

  private async doInitialize(ctx: common.UIAbilityContext): Promise<void> {
    this.context = ctx;
    this.snapshot.debuggable = ctx.applicationInfo.debug;
    const persistence = new HostPersistence(ctx);
    this.persistence = persistence;
    const settings = persistence.loadSettings();
    this.snapshot.settings = settings.settings;
    this.migrateProviderState();
    const chats = persistence.loadChats();
    this.applyChats(chats.document);
    this.snapshot.sessionsPhase = chats.failure.length > 0 ? LoadPhase.Failed : LoadPhase.Ready;
    this.snapshot.folders = chats.document.folders;
    this.snapshot.activeFolderId = chats.document.activeFolderId;
    if (chats.failure.length > 0) {
      this.snapshot.failure = chats.failure;
    } else if (settings.failure.length > 0) {
      this.snapshot.failure = settings.failure;
    } else if (chats.repaired) {
      this.snapshot.notice = this.uiCopy('上次运行中断的轮次已标记为已取消。');
    }
    this.proxy.setKeyProvider(async (): Promise<string> => {
      return await this.modelKey();
    });
    await this.syncKeyState();
    const boot = this.selectedProvider();
    this.bootProvider = boot === null ? null : cloneProviderProfile(boot);
    this.configureProxyRoute();
    this.initialized = true;
    if (chats.failure.length === 0 && settings.failure.length === 0) {
      this.persistNow();
    }
    await this.startNativeRuntime();
    this.emit();
  }

  private applyChats(document: StoredChatDocument): void {
    this.snapshot.sessions = document.sessions;
    this.snapshot.folders = document.folders;
    this.snapshot.activeSessionId = document.activeSessionId;
    this.snapshot.activeFolderId = document.activeFolderId;
    this.drafts.clear();
    for (let index = 0; index < document.drafts.length; index++) {
      this.drafts.set(document.drafts[index].sessionId, document.drafts[index].text);
    }
    const active = this.activeSession();
    if (active !== null) {
      this.snapshot.rows = this.cloneRows(active.rows);
      this.snapshot.title = active.title;
      const draft = this.drafts.get(active.id);
      this.snapshot.draft = draft === undefined ? '' : draft;
    } else {
      this.snapshot.rows = [];
      this.snapshot.title = '新会话';
      this.snapshot.draft = '';
    }
    this.sortSessions();
  }

  private startNativeRuntime(): Promise<void> {
    if (this.disposed) {
      return Promise.resolve();
    }
    if (this.runtimeStartPromise !== null) {
      return this.runtimeStartPromise;
    }
    const pending: Promise<void> = Promise.resolve().then(() => {
      return this.runNativeRuntimeStart();
    });
    this.runtimeStartPromise = pending;
    pending.then(() => {
      this.settleRuntimeStart(pending);
    }, () => {
      this.settleRuntimeStart(pending);
    });
    return pending;
  }

  private settleRuntimeStart(pending: Promise<void>): void {
    if (this.runtimeStartPromise === pending) {
      this.runtimeStartPromise = null;
    }
  }

  private async runNativeRuntimeStart(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.context === null || this.persistence === null) {
      this.snapshot.engine = EnginePhase.Failed;
      this.snapshot.failure = this.uiCopy('宿主上下文尚未初始化');
      this.emit();
      return;
    }
    const ctx = this.context;
    const repository = this.persistence;
    this.snapshot.engine = EnginePhase.Booting;
    this.snapshot.engineText = this.uiCopy('正在安装本地运行时');
    this.snapshot.failure = '';
    this.snapshot.runtimeUrl = '';
    this.workerReady = false;
    this.eventsReady = false;
    this.emit();
    const root = `${ctx.filesDir}/runtime`;
    const assets = `${ctx.filesDir}/runtime-assets`;
    try {
      this.ensureDirectory(root);
      this.ensureDirectory(assets);
    } catch (error) {
      this.engineFailed(this.uiCopy('无法创建私有运行时目录'));
      return;
    }
    let raw: Uint8Array;
    try {
      raw = await ctx.resourceManager.getRawFileContent('runtime.zip');
    } catch (error) {
      this.engineFailed(this.uiCopy('安装资源 runtime.zip 读取失败'));
      return;
    }
    if (this.disposed) {
      return;
    }
    let writeError = '';
    try {
      writeError = await repository.writeBundle(raw);
    } catch (error) {
      writeError = '私有文件写入失败';
    }
    if (this.disposed) {
      return;
    }
    if (writeError.length > 0) {
      this.engineFailed(writeError);
      return;
    }
    try {
      await native.installBundle(repository.runtimeBundlePath(), assets);
    } catch (error) {
      this.engineFailed(this.uiFill('运行时资源安装失败：{0}', [this.clean(errorText(error as Error))]));
      return;
    }
    if (this.disposed) {
      return;
    }
    try {
      native.setEventCallback((eventJson: string) => {
        this.onNativeEvent(eventJson);
      });
    } catch (error) {
      this.engineFailed(this.uiCopy('原生事件回调安装失败'));
      return;
    }
    const bootState = this.providerState();
    this.bootProvider = selectedProviderProfile(bootState);
    this.officialWebTools = await this.resolveOfficialWebTools(this.bootProvider);
    if (this.disposed) {
      return;
    }
    const launchError = this.writeModelLaunch(root, bootState);
    if (launchError.length > 0) {
      this.engineFailed(launchError);
      return;
    }
    this.configureProxyRoute();
    let infoText = '';
    try {
      infoText = await native.start(root, assets);
    } catch (error) {
      this.engineFailed(this.uiFill('本地运行时启动失败：{0}', [this.clean(errorText(error as Error))]));
      return;
    }
    if (this.disposed) {
      try {
        native.stop();
      } catch (error) {
      }
      return;
    }
    const info = this.parseNativeInfo(infoText);
    if (info.error.length > 0) {
      this.engineFailed(info.error);
      return;
    }
    if (info.port <= 0 || info.token.length === 0) {
      this.engineFailed(this.uiCopy('本地运行时没有返回可用的端口或启动令牌'));
      return;
    }
    this.nativeRunning = true;
    this.runtimeToken = info.token;
    const origin: string = `http://127.0.0.1:${info.port}`;
    this.proxy.setNativeOrigin(origin);
    try {
      webview.WebviewController.initializeWebEngine();
      await webview.WebCookieManager.configCookie(origin, `xl_launch_token=${info.token}; Path=/; HttpOnly; SameSite=Strict`, false, true);
    } catch (error) {
      native.stop();
      this.nativeRunning = false;
      this.engineFailed(this.uiCopy('本地运行时鉴权 cookie 配置失败'));
      return;
    }
    if (this.disposed) {
      try {
        native.stop();
      } catch (error) {
      }
      this.nativeRunning = false;
      this.runtimeToken = '';
      return;
    }
    this.snapshot.runtimeUrl = `${origin}/app/index.html`;
    this.snapshot.engine = EnginePhase.Booting;
    this.snapshot.engineText = this.uiCopy('本地运行时已启动，正在等待 Worker 就绪');
    this.snapshot.runtimeDetail = `port ${info.port}, boot ${info.bootId}, epoch ${info.sessionEpoch}, ackedMseq ${info.ackedMseq}`;
    this.configureProxyRoute();
    this.emit();
  }

  private engineFailed(message: string): void {
    if (this.disposed) {
      return;
    }
    this.nativeRunning = false;
    this.workerReady = false;
    this.snapshot.runtimeUrl = '';
    this.snapshot.engine = EnginePhase.Failed;
    this.snapshot.engineText = this.uiCopy('本地运行时启动失败');
    this.snapshot.failure = this.clean(message);
    this.snapshot.runtimeDetail = this.snapshot.failure;
    hilog.error(0x1A21, 'PDSHRuntime', '%{public}s', this.snapshot.failure);
    this.emit();
  }

  private onNativeEvent(eventJson: string): void {
    if (this.disposed) {
      return;
    }
    const event = parseJsonObject(eventJson);
    if (event === null) {
      return;
    }
    const type = jsonString(event, 'type');
    if (type === 'http-cancel') {
      // Native already made the request terminal (stop/timeout/peer abort).
      // Cancel the matching outbound RCP session before any late response.
      this.proxy.cancel(jsonNumber(event, 'id', -1));
      return;
    }
    if (type !== 'http') {
      return;
    }
    const id = jsonNumber(event, 'id', -1);
    this.proxy.handle(event).catch((error: Error) => {
      this.respond(id, 3, 502, '', toArrayBuffer(encodeUtf8('proxy_failure')));
    });
  }

  respond(id: number, kind: number, status: number, headersJson: string, body: ArrayBuffer): void {
    if (!this.nativeRunning) {
      return;
    }
    try {
      native.respond(id, kind, status, headersJson, body);
    } catch (error) {
    }
  }

  private parseNativeInfo(text: string): NativeRuntimeInfo {
    const info = new NativeRuntimeInfo();
    const row = parseJsonObject(text);
    if (row === null) {
      info.error = '原生启动结果不是 JSON';
      return info;
    }
    info.port = jsonNumber(row, 'port', 0);
    info.token = jsonString(row, 'token', '');
    info.bootId = jsonString(row, 'bootId', '');
    info.sessionEpoch = jsonNumber(row, 'sessionEpoch', 0);
    info.ackedMseq = jsonNumber(row, 'ackedMseq', 0);
    info.recoveredBytes = jsonNumber(row, 'recoveredBytes', 0);
    info.error = jsonString(row, 'error', '');
    return info;
  }

  private configureProxyRoute(): void {
    // Freeze to the profile this process booted with. A later save/select is a
    // record for the next start, never a live reroute of the running Worker.
    const profile = this.bootProvider !== null ? this.bootProvider : this.selectedProvider();
    const route = new ModelRouteConfig();
    if (profile !== null) {
      route.baseUrl = profile.baseUrl;
      route.model = profile.model;
      route.encoder = profile.encoder;
    }
    route.officialWebTools = this.officialWebTools;
    this.proxy.setRoute(route);
  }

  /**
   * The official Search/Fetch grant needs exactly two facts at startup: an
   * eligible official DeepSeek model base, and a model key this host can read
   * now. A missing or unreadable key leaves both tools disabled.
   */
  private async resolveOfficialWebTools(profile: ProviderProfileRecord | null): Promise<boolean> {
    if (profile === null || !officialWebModelBaseEligible(profile.baseUrl)) {
      return false;
    }
    try {
      const result: KeyReadResult = await this.secure.read(providerCredentialAlias(profile));
      return result.status === 'ok' && result.value.trim().length > 0;
    } catch (error) {
      return false;
    }
  }

  private async modelKey(): Promise<string> {
    const profile = this.bootProvider !== null ? this.bootProvider : this.selectedProvider();
    if (profile === null) {
      return '';
    }
    const result: KeyReadResult = await this.secure.read(providerCredentialAlias(profile));
    if (result.status === 'ok') {
      return result.value;
    }
    if (result.status === 'unreadable') {
      throw new Error('credential_unavailable');
    }
    return '';
  }

  private async syncKeyState(): Promise<void> {
    const profiles: ProviderProfileRecord[] = cloneProviderProfiles(this.snapshot.settings.providerProfiles);
    let selectedUnreadable = false;
    for (let index = 0; index < profiles.length; index++) {
      const profile = profiles[index];
      const result: KeyReadResult = await this.secure.read(providerCredentialAlias(profile));
      profile.keyConfigured = result.status === 'ok';
      if (profile.id === this.snapshot.settings.selectedProviderId && result.status === 'unreadable') {
        selectedUnreadable = true;
      }
    }
    this.snapshot.settings.providerProfiles = profiles;
    this.projectLegacyProvider();
    if (selectedUnreadable && this.snapshot.failure.length === 0) {
      this.snapshot.failure = this.uiCopy('密钥存储无法读取；模型请求会被宿主拒绝。');
    }
  }

  private migrateProviderState(): void {
    const provider: ProviderConfig = this.snapshot.settings.provider;
    const legacy: LegacyProvider = {
      id: provider.id,
      name: provider.name,
      baseUrl: provider.baseUrl,
      model: provider.model,
      effort: provider.effort,
      encoder: provider.encoder
    };
    const state: ProviderProfilesState = migrateProviderProfiles(
      legacy,
      this.snapshot.settings.providerProfiles,
      this.snapshot.settings.selectedProviderId
    );
    this.snapshot.settings.providerProfiles = cloneProviderProfiles(state.profiles);
    this.snapshot.settings.selectedProviderId = state.selectedId;
    this.projectLegacyProvider();
  }

  private providerState(): ProviderProfilesState {
    const state = new ProviderProfilesState();
    state.profiles = cloneProviderProfiles(this.snapshot.settings.providerProfiles);
    state.selectedId = this.snapshot.settings.selectedProviderId;
    return state;
  }

  private selectedProvider(): ProviderProfileRecord | null {
    return selectedProviderProfile(this.providerState());
  }

  private providerConfigFrom(profile: ProviderProfileRecord): ProviderConfig {
    const next = new ProviderConfig();
    next.id = profile.id;
    next.name = profile.name;
    next.baseUrl = profile.baseUrl;
    next.model = profile.model;
    next.effort = profile.effort;
    next.encoder = profile.encoder;
    next.keyConfigured = profile.keyConfigured;
    return next;
  }

  private settingsForProvider(state: ProviderProfilesState): Settings {
    const next = this.cloneSettings(this.snapshot.settings);
    next.providerProfiles = cloneProviderProfiles(state.profiles);
    next.selectedProviderId = state.selectedId;
    const selected = selectedProviderProfile(state);
    if (selected !== null) {
      next.provider = this.providerConfigFrom(selected);
    } else {
      const unset = new ProviderConfig();
      unset.keyConfigured = false;
      next.provider = unset;
    }
    return next;
  }

  private applyProviderState(state: ProviderProfilesState): void {
    this.snapshot.settings.providerProfiles = cloneProviderProfiles(state.profiles);
    this.snapshot.settings.selectedProviderId = state.selectedId;
    this.projectLegacyProvider();
  }

  private projectLegacyProvider(): void {
    const selected = this.selectedProvider();
    if (selected !== null) {
      this.snapshot.settings.provider = this.providerConfigFrom(selected);
      return;
    }
    const unset = new ProviderConfig();
    unset.keyConfigured = false;
    this.snapshot.settings.provider = unset;
  }

  private updateProviderKeyFact(id: string, configured: boolean): void {
    for (let index = 0; index < this.snapshot.settings.providerProfiles.length; index++) {
      if (this.snapshot.settings.providerProfiles[index].id === id) {
        this.snapshot.settings.providerProfiles[index].keyConfigured = configured;
      }
    }
    if (this.snapshot.settings.selectedProviderId === id) {
      this.snapshot.settings.provider.keyConfigured = configured;
    }
  }

  private nextProviderId(state: ProviderProfilesState): string {
    for (let attempt = 0; attempt < 8; attempt++) {
      const candidate: string = uniqueId('provider');
      if (findProviderProfile(state, candidate) === null) {
        return candidate;
      }
    }
    return `provider-${Date.now().toString(36)}`;
  }

  private writeModelLaunch(root: string, state: ProviderProfilesState): string {
    if (this.persistence === null) {
      return '私有存储不可用';
    }
    const path: string = `${root}/${PROVIDER_LAUNCH_FILE}`;
    if (this.bootProvider === null) {
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
        }
      } catch (error) {
      }
      return '';
    }
    const document: string = providerLaunchDocument(state, this.officialWebTools);
    if (document.length === 0 || providerLaunchSelectedModel(state).length === 0) {
      return '模型服务投影为空，无法启动本地引擎';
    }
    return this.persistence.writeAtomic(path, encodeUtf8(document));
  }

  private rejectProvider(message: string): void {
    this.snapshot.failure = message;
    this.snapshot.notice = '';
    this.emit();
    throw new Error(message);
  }

  private async updatePermissionPreset(mode: string): Promise<void> {
    const revision = await this.permissionRevision();
    const patch: Record<string, Object> = {};
    patch['defaultPreset'] = mode;
    const args: SettingsUpdateArgs = { ns: 'permission', patch: patch };
    if (revision >= 0) {
      args.expectedRevision = revision;
    }
    await this.pageBridge.call('settings/update', args as Object, 5000);
  }

  private async permissionRevision(): Promise<number> {
    try {
      const value = await this.pageBridge.call('settings/describe', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      const namespaces = asArray(root === null ? null : root['namespaces']);
      for (let index = 0; index < namespaces.length; index++) {
        const row = asRecord(namespaces[index]);
        if (row !== null && jsonString(row, 'ns') === 'permission') {
          return jsonNumber(row, 'revision', -1);
        }
      }
    } catch (error) {
    }
    return -1;
  }

  private waitEventsReady(timeoutMillis: number): Promise<boolean> {
    if (this.eventsReady) {
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      const timer = setTimeout(() => {
        this.eventsWaiter = null;
        resolve(false);
      }, timeoutMillis);
      this.eventsWaiter = () => {
        clearTimeout(timer);
        resolve(this.eventsReady);
      };
    });
  }

  private async ensureEventStream(): Promise<void> {
    if (this.eventsReady) {
      return;
    }
    await this.pageBridge.callEvents();
    await this.waitEventsReady(5000);
  }

  private async promptOnce(requestId: string, session: SessionRecord, text: string, mode: string): Promise<void> {
    if (session.workerSessionId.length === 0) {
      throw new Error('Worker 会话不存在');
    }
    const content: PromptContent[] = promptContent(text);
    const request: SessionPromptRequest = {
      requestId: requestId,
      sessionId: session.workerSessionId,
      mode: mode,
      content: content
    };
    const args: SessionPromptArgs = { request: request };
    await this.pageBridge.call('session/prompt', args as Object, 60000);
  }

  private workerSessionGone(message: string): boolean {
    return message.includes('session/not-found') || message.includes('session/not_found');
  }

  private failSend(text: string, message: string): void {
    this.pendingTurns = this.pendingTurns > 0 ? this.pendingTurns - 1 : 0;
    this.snapshot.running = this.pendingTurns > 0;
    this.snapshot.stopping = false;
    this.snapshot.draft = text;
    if (this.snapshot.activeSessionId.length > 0) {
      this.drafts.set(this.snapshot.activeSessionId, text);
    }
    this.snapshot.failure = this.uiFill('发送失败：{0}', [message]);
    this.appendRow(this.errorRow(this.uiCopy('发送失败'), message));
    if (this.pendingTurns === 0) {
      this.pendingOwnQueueRequestIds = [];
      this.endArtifacts();
      this.closeActiveStream();
    }
    this.persistNow();
    this.emit();
  }

  private async ensureWorkerSession(session: SessionRecord): Promise<boolean> {
    if (session.workerSessionId.length > 0) {
      return true;
    }
    const request: SessionCreateRequest = { cwd: '/dsh/workspace' };
    const args: SessionCreateArgs = { request: request };
    let last = '';
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const value = await this.pageBridge.call('session/create', args as Object, 20000);
        const row = asRecord(value);
        const id = jsonString(row, 'sessionId', '');
        if (id.length > 0) {
          session.workerSessionId = id;
          session.updatedAt = Date.now();
          this.persistNow();
          this.emit();
          this.refreshControlsQuietly();
          return true;
        }
        last = 'session/create 没有返回 sessionId';
      } catch (error) {
        last = this.clean(errorText(error as Error));
      }
      if (attempt < 3) {
        await delay(350 * (attempt + 1));
      }
    }
    this.snapshot.failure = this.uiFill('无法建立 Worker 会话：{0}', [last]);
    return false;
  }

  private async openFollow(session: SessionRecord): Promise<void> {
    if (session.workerSessionId.length === 0) {
      throw new Error('Worker 会话不存在');
    }
    if (this.activeStreamId.length > 0 && this.activeStreamSessionId === session.id) {
      return;
    }
    if (this.activeStreamId.length > 0) {
      await this.closeActiveStream();
    }
    const streamId = uniqueId('follow');
    this.followSeen.delete(streamId);
    this.activeStreamId = streamId;
    this.activeStreamSessionId = session.id;
    this.streamClosedByUs = false;
    const args: FollowArgs = { sessionId: session.workerSessionId, streamId: streamId };
    try {
      await this.pageBridge.call('$follow', args as Object, 15000);
      await this.waitFollowSignal(streamId, 1500);
    } catch (error) {
      this.activeStreamId = '';
      this.activeStreamSessionId = '';
      throw new Error(errorText(error as Error));
    }
  }

  private waitFollowSignal(streamId: string, timeoutMillis: number): Promise<void> {
    if (this.followSeen.has(streamId)) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      const timer = setTimeout(() => {
        this.followWaiters.delete(streamId);
        resolve();
      }, timeoutMillis);
      this.followWaiters.set(streamId, () => {
        clearTimeout(timer);
        this.followWaiters.delete(streamId);
        resolve();
      });
    });
  }

  private async closeActiveStream(): Promise<void> {
    const streamId = this.activeStreamId;
    if (streamId.length === 0) {
      return;
    }
    this.activeStreamId = '';
    this.activeStreamSessionId = '';
    this.streamClosedByUs = true;
    this.followSeen.delete(streamId);
    const waiter = this.followWaiters.get(streamId);
    if (waiter !== undefined) {
      waiter();
    }
    const args: CloseStreamArgs = { streamId: streamId };
    try {
      await this.pageBridge.call('$close', args as Object, 3000);
    } catch (error) {
    }
  }

  private closeAllStreams(): void {
    const follow = this.activeStreamId;
    this.activeStreamId = '';
    this.activeStreamSessionId = '';
    if (follow.length > 0) {
      const args: CloseStreamArgs = { streamId: follow };
      this.pageBridge.call('$close', args as Object, 1000).catch((error: Error) => {
      });
    }
    if (this.eventsReady) {
      this.eventsReady = false;
      const events: EventsArgs = { streamId: 'events' };
      this.pageBridge.call('$close', events as Object, 1000).catch((error: Error) => {
      });
    }
  }

  private handleEventsValue(value: Object): void {
    const row = asRecord(value);
    if (row === null) {
      return;
    }
    const type = jsonString(row, 'type');
    if (type === 'ready') {
      this.eventsReady = true;
      this.eventsClientId = jsonString(row, 'clientId', '');
      if (this.eventsWaiter !== null) {
        const waiter = this.eventsWaiter;
        this.eventsWaiter = null;
        waiter();
      }
      return;
    }
    if (type === 'cancel') {
      const eventId = jsonString(row, 'eventId', '');
      if (eventId.length > 0) {
        this.removePending(eventId);
        this.emit();
      }
      return;
    }
    if (type !== 'waterfall') {
      return;
    }
    const eventKind = jsonString(row, 'event', '');
    if (eventKind !== 'approval/request' && eventKind !== 'user-questions/request') {
      return;
    }
    const agentId = jsonString(row, 'agentId', '');
    const active = this.activeSession();
    if (active === null || active.workerSessionId !== agentId) {
      return;
    }
    const eventId = jsonString(row, 'eventId', '');
    if (eventId.length === 0) {
      return;
    }
    const body = asRecord(row['request']);
    const meta = new PendingMeta();
    meta.id = eventId;
    meta.clientId = this.eventsClientId;
    meta.eventKind = eventKind;
    meta.body = body;
    this.pendingMeta.set(eventId, meta);
    const pending = new PendingRequest();
    pending.id = eventId;
    pending.kind = eventKind === 'user-questions/request' ? 'question' : 'permission';
    pending.title = this.pendingTitle(body, eventKind);
    pending.detail = this.pendingDetail(body, eventKind);
    pending.choices = this.pendingChoices(body, eventKind);
    if (pending.kind === 'question') {
      try {
        pending.questions = parseQuestionItems(body);
      } catch (error) {
        this.pendingMeta.delete(eventId);
        this.snapshot.failure = this.uiFill('问题请求无效：{0}', [this.clean(errorText(error as Error))]);
        this.emit();
        return;
      }
    }
    const next: PendingRequest[] = [];
    for (let index = 0; index < this.snapshot.pending.length; index++) {
      if (this.snapshot.pending[index].id !== eventId) {
        next.push(this.snapshot.pending[index]);
      }
    }
    next.push(pending);
    this.snapshot.pending = next;
    this.emit();
  }

  private handleFollowValue(value: Object): void {
    const row = asRecord(value);
    if (row === null) {
      return;
    }
    const type = jsonString(row, 'type');
    if (type === 'event') {
      const event = asRecord(row['event']);
      if (event !== null) {
        this.handleWorkerEvent(event);
      }
      return;
    }
    if (type === 'assistant-stream') {
      const frame = asRecord(row['frame']);
      if (frame === null || jsonString(frame, 'type') !== 'chunk') {
        return;
      }
      const chunk = asRecord(frame['chunk']);
      if (chunk === null) {
        return;
      }
      const chunkType = jsonString(chunk, 'type');
      const text = jsonString(chunk, 'text', '');
      if (chunkType === 'text-delta' && text.length > 0) {
        this.snapshot.streamingText += text;
        this.emitStreaming();
      } else if (chunkType === 'reasoning-delta' && text.length > 0) {
        this.snapshot.reasoningText += text;
        this.emitStreaming();
      }
      return;
    }
    if (type === 'snapshot') {
      // The opening snapshot is the Worker's own durable history (`records` of
      // `{ type: 'event', event }`), not a replay of local rows. Adopt its rows
      // with stable seq ids so a restart recovers real user/assistant/tool rows
      // without duplicating the ones already stored. Active stream text and the
      // running flag are deliberately left alone.
      const active = this.activeSession();
      if (active === null || active.workerSessionId.length === 0) {
        return;
      }
      const header = asRecord(row['header']);
      const owner = jsonString(header, 'id', '');
      if (owner.length > 0 && owner !== active.workerSessionId) {
        // A snapshot from a replaced Worker session must not land in this
        // conversation's transcript.
        return;
      }
      const projection: FollowSnapshotProjection =
        projectFollowSnapshot(row, active.workerSessionId);
      if (!projection.present || projection.rows.length === 0) {
        return;
      }
      this.mergeTranscript(projection.rows);
      this.emit();
      return;
    }
    if (type === 'error') {
      const error = asRecord(row['error']);
      const message = jsonString(error, 'message', '会话事件流报告错误');
      this.snapshot.failure = this.clean(message);
      this.appendRow(this.errorRow(this.uiCopy('会话错误'), this.clean(message)));
      this.emit();
    }
  }

  private handleWorkerEvent(event: Record<string, Object>): void {
    const type = jsonString(event, 'type');
    const session = this.activeSession();
    const workerSessionId = session === null ? '' : session.workerSessionId;
    if (type === 'assistant/message') {
      const data = asRecord(event['data']);
      const text = this.assistantText(data);
      if (text.length > 0) {
        const reasoning = this.snapshot.reasoningText;
        this.snapshot.streamingText = '';
        this.snapshot.reasoningText = '';
        const projected = projectEvent(event, workerSessionId);
        this.stampActiveTurn(projected);
        let hasThinking = false;
        for (let index = 0; index < projected.length; index++) {
          if (projected[index].kind === RowKind.Thinking) {
            hasThinking = true;
          }
        }
        if (!hasThinking && reasoning.length > 0) {
          // Older Worker payloads may not repeat reasoning in the durable
          // message. Keep the live reasoning row as a fallback, never in
          // addition to a projected one.
          const thinking = new ChatRow();
          thinking.id = uniqueId('row');
          thinking.kind = RowKind.Thinking;
          thinking.text = reasoning;
          thinking.status = 'done';
          thinking.createdAt = Date.now();
          this.stampRow(thinking);
          this.appendRow(thinking);
        }
        if (projected.length === 0) {
          const row = new ChatRow();
          row.id = uniqueId('row');
          row.kind = RowKind.Assistant;
          row.text = text;
          row.status = 'done';
          row.createdAt = Date.now();
          this.stampRow(row);
          this.appendRow(row);
        } else {
          this.mergeTranscript(projected);
        }
      } else {
        this.flushStreamText('', true);
      }
      this.emit();
      return;
    }
    if (type === 'user/message' || type === 'tool/call' || type === 'tool/result') {
      // The live frame and the snapshot record share the same stable seq id;
      // mergeTranscript adopts an optimistic user row and updates the tool row
      // a prior call already created.
      const projected = projectEvent(event, workerSessionId);
      if (type === 'user/message') {
        const admitted = admittedUserPromptRequestId(event);
        if (admitted.length > 0) {
          const beforeLocal = this.snapshot.localQueueItems.length;
          this.snapshot.localQueueItems = retireLocalQueuePrompt(
            this.snapshot.localQueueItems, admitted);
          const retired = retireOwnedQueueRequest(this.pendingOwnQueueRequestIds, admitted);
          this.pendingOwnQueueRequestIds = retired.remaining;
          if (beforeLocal !== this.snapshot.localQueueItems.length || retired.removed) {
            this.refreshQueueQuietly();
          }
        }
      }
      if (this.snapshot.debuggable && (type === 'tool/call' || type === 'tool/result')) {
        const data = asRecord(event['data']);
        const message = asRecord(data === null ? null : data['message']);
        const source = asRecord(message === null ? null : message['source']);
        hilog.info(0x1A21, 'PDSHProjection',
          'tool type=%{public}s seq=%{public}d call=%{public}s sourceCall=%{public}s row=%{public}s',
          type, jsonNumber(event, 'seq', -1), jsonString(data, 'callId', ''),
          jsonString(source, 'callId', ''), projected.length > 0 ? projected[0].id : 'none');
      }
      if (projected.length > 0) {
        this.stampActiveTurn(projected);
        this.mergeTranscript(projected);
      }
      this.emit();
      return;
    }
    if (type === 'turn/start') {
      this.beginTurn(event);
      if (!this.snapshot.running) {
        this.snapshot.running = true;
        this.pendingTurns = Math.max(this.pendingTurns, 1);
      }
      this.emit();
      this.refreshQueueQuietly();
      return;
    }
    if (type === 'turn/end') {
      const data = asRecord(event['data']);
      const reason = asRecord(data === null ? null : data['reason']);
      const kind = jsonString(reason, 'kind', 'unknown');
      // The title stays `本轮结束：kind`; the detail carries the Worker's own
      // sanitized provider failure instead of a generic reason.
      const detail = this.clean(turnEndDetailOf(event));
      const projected = projectEvent(event, workerSessionId);
      const turnEndRow: TranscriptRow | null = projected.length > 0 ? projected[0] : null;
      if (turnEndRow !== null) {
        // `clean()` owns the last redaction pass before the row reaches ArkUI.
        turnEndRow.detail = detail;
        turnEndRow.text = detail.length > 0
          ? `本轮结束：${kind} · ${detail}`
          : `本轮结束：${kind}`;
      }
      this.finishTurn(kind, detail, turnEndRow);
      this.closeTurn(event, kind);
      this.emit();
      if (this.pendingTurns === 0) {
        this.refreshControlsQuietly();
      } else {
        this.refreshQueueQuietly();
      }
      return;
    }
    if (type === 'error') {
      const data = asRecord(event['data']);
      const message = jsonString(data, 'message', 'Worker 报告错误');
      this.snapshot.failure = this.clean(message);
      this.appendRow(this.errorRow(this.uiCopy('Worker 错误'), this.clean(message)));
      this.emit();
      return;
    }
    // permission/request, question/request, session/start and unknown future
    // types are not transcript rows here. Live approvals arrive on the $events
    // waterfall; durable approvals are best-effort.
  }

  /** Opens the timeline window from the Worker's own `turn/start` event. */
  private beginTurn(event: Record<string, Object>): void {
    const data = asRecord(event['data']);
    const turn = jsonNumber(data, 'turn', 0);
    const at = jsonNumber(event, 'time', -1);
    this.activeTurnId = 'turn-' + turn.toString();
    this.activeTurnStartedAt = at >= 0 ? at : 0;
  }

  /** Stamps rows created inside the open turn with its id and Worker start time. */
  private stampActiveTurn(rows: TranscriptRow[]): void {
    for (let index = 0; index < rows.length; index++) {
      this.stampRow(rows[index]);
    }
  }

  private stampRow(row: ChatRow): void {
    if (this.activeTurnId.length === 0 || this.activeTurnStartedAt <= 0) {
      return;
    }
    if (row.kind === RowKind.User) {
      return;
    }
    row.turnId = this.activeTurnId;
    row.turnStartedAt = this.activeTurnStartedAt;
    row.turnEndedAt = 0;
    row.turnOutcome = TurnOutcome.Running;
  }

  /** Closes the open turn with the Worker's `turn/end` time and reason. */
  private closeTurn(event: Record<string, Object>, reasonKind: string): void {
    if (this.activeTurnId.length === 0) {
      return;
    }
    const at = jsonNumber(event, 'time', -1);
    const outcome = turnOutcomeOf(reasonKind);
    let changed = false;
    for (let index = 0; index < this.snapshot.rows.length; index++) {
      const row = this.snapshot.rows[index];
      // A stopped turn flushes its partial stream inside finishTurn, after the
      // durable rows were stamped; adopt that same-turn row here. User rows and
      // system status rows stay out of the turn tail.
      const adrift = row.turnId.length === 0
        && (row.kind === RowKind.Assistant || row.kind === RowKind.Thinking || row.kind === RowKind.Tool)
        && row.createdAt >= this.activeTurnStartedAt && this.activeTurnStartedAt > 0;
      if (row.turnId !== this.activeTurnId && !adrift) {
        continue;
      }
      if (adrift) {
        row.turnId = this.activeTurnId;
        row.turnStartedAt = this.activeTurnStartedAt;
      }
      row.turnOutcome = outcome;
      row.turnEndedAt = at >= 0 ? at : 0;
      changed = true;
    }
    this.activeTurnId = '';
    this.activeTurnStartedAt = 0;
    if (changed) {
      this.persistSoon();
    }
  }

  /**
   * Fold projected Worker rows into the stored transcript.
   *
   * Exact stable ids update in place, legacy random-id rows are adopted by
   * call id or text, and rows with no counterpart append. The emit belongs to
   * the caller so a streaming frame is not published twice.
   */
  private mergeTranscript(projected: TranscriptRow[]): void {
    if (projected.length === 0) {
      return;
    }
    const merged: TranscriptMergeResult = mergeTranscriptRows(this.snapshot.rows, projected);
    if (merged.appended === 0 && merged.adopted === 0) {
      return;
    }
    this.snapshot.rows = merged.rows;
    const session = this.activeSession();
    if (session !== null) {
      session.rows = merged.rows.slice();
      session.updatedAt = Date.now();
    }
    this.persistSoon();
  }

  private finishTurn(reason: string, detail: string, turnEndRow: TranscriptRow | null): void {
    this.pendingTurns = this.pendingTurns > 0 ? this.pendingTurns - 1 : 0;
    this.snapshot.running = this.pendingTurns > 0;
    this.snapshot.stopping = false;
    if (this.pendingTurns === 0) {
      this.pendingOwnQueueRequestIds = [];
      this.endArtifacts();
    }
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    this.flushStreamText(reason, true);
    if (reason !== 'completed' && reason !== 'unknown') {
      if (turnEndRow !== null) {
        this.appendRow(turnEndRow);
      } else if (detail.length > 0) {
        this.appendRow(this.errorRow(this.uiFill('本轮结束：{0} · {1}', [reason, detail]), detail));
      } else {
        this.appendRow(this.errorRow(this.uiFill('本轮结束：{0}', [reason]), ''));
      }
    }
    if (this.pendingTurns === 0) {
      this.closeActiveStream();
    }
    this.persistNow();
    this.emit();
  }

  private emitStreaming(): void {
    if (this.streamEmitTimer >= 0) {
      return;
    }
    this.streamEmitTimer = setTimeout(() => {
      this.streamEmitTimer = -1;
      this.emit();
    }, 40);
  }

  private flushStreamText(reason: string, keepReasoning: boolean): void {
    const text = this.snapshot.streamingText;
    if (text.length > 0) {
      const row = new ChatRow();
      row.id = uniqueId('row');
      row.kind = RowKind.Assistant;
      row.text = text;
      row.status = reason === 'completed' ? 'done' : 'interrupted';
      row.createdAt = Date.now();
      this.appendRow(row);
    }
    if (keepReasoning && this.snapshot.reasoningText.length > 0) {
      const thinking = new ChatRow();
      thinking.id = uniqueId('row');
      thinking.kind = RowKind.Thinking;
      thinking.text = this.snapshot.reasoningText;
      thinking.status = reason === 'completed' ? 'done' : 'interrupted';
      thinking.createdAt = Date.now();
      this.appendRow(thinking);
    }
    this.snapshot.streamingText = '';
    this.snapshot.reasoningText = '';
  }

  private assistantText(data: Record<string, Object> | null): string {
    if (data === null) {
      return '';
    }
    const direct = jsonString(data, 'text', '');
    if (direct.length > 0) {
      return direct;
    }
    const message = asRecord(data['message']);
    const content = asArray(message === null ? null : message['content']);
    const blocks = content.length > 0 ? content : asArray(data['content']);
    let text = '';
    for (let index = 0; index < blocks.length; index++) {
      const block = asRecord(blocks[index]);
      if (block !== null && jsonString(block, 'type') === 'text') {
        text += jsonString(block, 'text', '');
      }
    }
    if (text.length > 0) {
      return text;
    }
    if (message !== null) {
      return jsonString(message, 'text', '');
    }
    return '';
  }

  private appendRow(row: ChatRow): void {
    // Stable Worker ids make append idempotent; the snapshot and a live event can
    // describe the same durable row, and an optimistic row can already carry it.
    if (row.id.length > 0) {
      for (let index = 0; index < this.snapshot.rows.length; index++) {
        if (this.snapshot.rows[index].id === row.id) {
          return;
        }
      }
    }
    this.snapshot.rows.push(row);
    const session = this.activeSession();
    if (session !== null) {
      session.rows.push(row);
      session.updatedAt = Date.now();
      if (row.kind === RowKind.User && (session.title === '新会话' || session.title.length === 0)) {
        session.title = this.titleFor(row.text);
        this.snapshot.title = session.title;
      }
    }
  }

  private errorRow(title: string, detail: string): ChatRow {
    const row = new ChatRow();
    row.id = uniqueId('row');
    row.kind = RowKind.Error;
    row.text = title;
    row.detail = detail;
    row.status = 'failed';
    row.createdAt = Date.now();
    return row;
  }

  private armStopTimeout(): void {
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
    }
    this.stopTimer = setTimeout(() => {
      this.stopTimer = -1;
      if (!this.snapshot.stopping || !this.snapshot.running) {
        return;
      }
      this.snapshot.stopping = false;
      this.snapshot.running = false;
      this.pendingTurns = 0;
      this.endArtifacts();
      this.clearQueueState();
      this.snapshot.failure = this.uiCopy('取消请求已发送，但运行时未在 10 秒内确认本轮结束。');
      this.appendRow(this.errorRow(this.uiCopy('取消未确认'), 'Worker 没有报告 turn/end；本地界面已停止等待。'));
      this.closeActiveStream();
      this.persistNow();
      this.emit();
    }, 10000);
  }

  // ---------------------------------------------------- session artifacts

  private clearArtifactsMeasurement(): void {
    this.artifactsOpen = false;
    this.artifactsSessionId = '';
    this.artifactsFromMseq = '';
  }

  /** The cached ACK may only be read once Native and the Worker are ready. */
  private artifactsReady(): boolean {
    return this.nativeRunning && this.workerReady && this.snapshot.engine === EnginePhase.Ready;
  }

  /** Canonical decimal u64 text, or '' when it is not a valid non-negative int. */
  private decimalMseq(text: string): string {
    if (text.length === 0 || text.length > 20) {
      return '';
    }
    for (let index = 0; index < text.length; index++) {
      const code = text.charCodeAt(index);
      if (code < 48 || code > 57) {
        return '';
      }
    }
    let start = 0;
    while (start < text.length - 1 && text.charAt(start) === '0') {
      start++;
    }
    return text.substring(start);
  }

  /** Lexicographic decimal compare for u64 strings; avoids JS number rounding. */
  private compareMseq(left: string, right: string): number {
    if (left.length !== right.length) {
      return left.length < right.length ? -1 : 1;
    }
    if (left === right) {
      return 0;
    }
    return left < right ? -1 : 1;
  }

  /** Cached ACK read: O(1), no Store lock, no filesystem scan, no await. */
  private readWorkspaceWatermark(): string {
    if (!this.artifactsReady()) {
      return '';
    }
    try {
      const root = parseJsonObject(native.workspaceWatermark());
      if (root === null || jsonString(root, 'error', '').length > 0) {
        return '';
      }
      return this.decimalMseq(jsonString(root, 'ackedMseq', ''));
    } catch (error) {
      return '';
    }
  }

  /**
   * Stamps the ACK before the first pending prompt. Queued turns share one
   * measured range per session; they are not attributed turn by turn.
   */
  private beginArtifacts(session: SessionRecord): void {
    if (this.artifactsOpen) {
      return;
    }
    const previous = session.artifactsFromMseq === undefined ? '' :
      this.decimalMseq(session.artifactsFromMseq);
    const from = previous.length > 0 ? previous : this.readWorkspaceWatermark();
    if (from.length === 0) {
      return;
    }
    session.artifactsFromMseq = from;
    this.artifactsOpen = true;
    this.artifactsSessionId = session.id;
    this.artifactsFromMseq = from;
  }

  /** Stamps the final ACK after the last pending turn and measures the range. */
  private endArtifacts(): void {
    if (!this.artifactsOpen) {
      return;
    }
    const from = this.artifactsFromMseq;
    const sessionId = this.artifactsSessionId;
    this.clearArtifactsMeasurement();
    const to = this.readWorkspaceWatermark();
    if (from.length === 0 || to.length === 0 || this.compareMseq(to, from) < 0) {
      // Renderer loss, host teardown or a regressed ACK: preserve the previous
      // known paths but publish Unknown, never a fabricated empty measurement.
      this.applyArtifacts(sessionId, null, LoadPhase.Unknown);
      return;
    }
    if (this.compareMseq(to, from) === 0) {
      this.applyArtifacts(sessionId, [], LoadPhase.Ready);
      return;
    }
    this.collectArtifacts(sessionId, from, to).catch((error: Error) => {
      this.applyArtifacts(sessionId, null, LoadPhase.Unknown);
    });
  }

  private async collectArtifacts(sessionId: string, from: string, to: string): Promise<void> {
    const root = parseJsonObject(await native.workspaceChanges(from, to));
    if (root === null || jsonString(root, 'error', '').length > 0) {
      this.applyArtifacts(sessionId, null, LoadPhase.Unknown);
      return;
    }
    const rows = asArray(root['files']);
    const measured: SessionArtifact[] = [];
    for (let index = 0; index < rows.length && measured.length < 2000; index++) {
      const row = asRecord(rows[index]);
      if (row === null) {
        continue;
      }
      const path = jsonString(row, 'path', '');
      if (!path.startsWith('/dsh/workspace/')) {
        continue;
      }
      const entry = new SessionArtifact();
      entry.path = path;
      entry.size = jsonNumber(row, 'size', 0);
      entry.mseq = jsonString(row, 'mseq', '');
      measured.push(entry);
    }
    this.applyArtifacts(sessionId, measured, LoadPhase.Ready);
  }

  /**
   * Applies a measurement by session id. The async native call may outlive the
   * row it started from, so the session is looked up again; a stale reference
   * must not be written.
   */
  private applyArtifacts(sessionId: string, measured: SessionArtifact[] | null,
    phase: LoadPhase): void {
    const session = this.findSession(sessionId);
    if (session === null) {
      return;
    }
    if (measured !== null) {
      session.artifacts = measured;
    }
    session.artifactsPhase = phase;
    this.persistNow();
    if (this.snapshot.page === Page.SessionArtifacts &&
      this.snapshot.activeSessionId === sessionId) {
      this.loadArtifacts();
    }
    this.emit();
  }

  /**
   * Projects only stored, measured facts. It never starts a VFS scan: a scan
   * around a prompt would race cancellation and a legacy session has no
   * measurement to project, so it stays Unknown instead of an empty Ready.
   */
  private loadArtifacts(): void {
    const session = this.activeSession();
    this.snapshot.items = [];
    if (session === null || session.artifactsPhase === undefined) {
      this.snapshot.itemsPhase = LoadPhase.Unknown;
      return;
    }
    if (session.artifactsPhase === LoadPhase.Failed) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      return;
    }
    if (session.artifactsPhase !== LoadPhase.Ready) {
      this.snapshot.itemsPhase = LoadPhase.Unknown;
      return;
    }
    const measured = session.artifacts === undefined ? [] : session.artifacts;
    const items: NamedItem[] = [];
    for (let index = 0; index < measured.length; index++) {
      const artifact = measured[index];
      if (!artifact.path.startsWith('/dsh/workspace/')) {
        continue;
      }
      const item = new NamedItem();
      item.id = artifact.path;
      item.title = baseName(artifact.path);
      item.subtitle = `${artifact.size} 字节 · mseq ${artifact.mseq}`;
      item.detail = artifact.path;
      items.push(item);
    }
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
  }

  // --------------------------------------------------------- page loading

  private async loadForPage(): Promise<void> {
    const page = this.snapshot.page;
    const generation = this.loadGeneration + 1;
    this.loadGeneration = generation;
    this.itemMeta.clear();
    this.automationRecords.clear();
    this.modelChoices = [];
    this.snapshot.items = [];
    this.snapshot.itemsPhase = LoadPhase.Loading;
    this.snapshot.failure = '';
    this.emit();
    try {
      if (page === Page.Configuration || page === Page.WebSearch ||
        page === Page.SettingsDocument || page === Page.PluginInventory || page === Page.AgentPresets) {
        await this.loadConfiguration(page);
      } else if (page === Page.Mcp || page === Page.McpEditor) {
        await this.loadMcp();
      } else if (page === Page.PhonePermissions) {
        await this.loadPhonePermissions();
      } else if (page === Page.Tools) {
        await this.loadTools();
      } else if (page === Page.Automation) {
        await this.loadAutomation();
      } else if (page === Page.SessionArtifacts) {
        this.loadArtifacts();
      } else if (page === Page.Files) {
        await this.loadFiles();
      } else if (page === Page.Preview) {
        await this.loadPreview();
      } else if (page === Page.Runtime) {
        this.loadRuntime();
      } else if (page === Page.Egress) {
        this.loadForPageEgress();
      } else if (page === Page.Probes) {
        await this.loadProbes();
      } else if (page === Page.DeviceConnection) {
        this.loadUnsupportedFacts();
      } else if (page === Page.ArchivedSessions) {
        this.loadArchivedSessions();
      } else if (page === Page.FontSize) {
        this.loadFontSizes();
      } else if (page === Page.Shortcuts) {
        this.loadShortcuts();
      } else if (page === Page.About) {
        this.loadAbout(page);
      } else if (page === Page.Licenses) {
        await this.loadLicenses();
      } else {
        // No loader means no reading happened. Ready + [] would claim the page
        // was read and is empty; Unknown keeps "not measured" distinct.
        this.snapshot.items = [];
        this.snapshot.itemsPhase = LoadPhase.Unknown;
      }
    } catch (error) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.clean(errorText(error as Error));
    }
    if (this.loadGeneration === generation && this.snapshot.page === page) {
      this.emit();
    }
  }

  /**
   * Read the phone-permission matrix from this device's own bundle/grant APIs.
   * The page is read-only: no permission is requested and no Worker command is
   * sent, so an absent row stays 未知 instead of borrowing a plausible state.
   */
  private async loadPhonePermissions(): Promise<void> {
    const items: NamedItem[] = await HostPhonePermissions.read(this.uiLanguage());
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
    this.snapshot.failure = '';
  }

  private async loadConfiguration(page: Page): Promise<void> {
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法读取配置');
      return;
    }
    const failures: string[] = [];
    const items: NamedItem[] = [];
    if (page === Page.Configuration) {
      await this.readModelChoices(failures);
    }
    if (page === Page.Configuration || page === Page.WebSearch || page === Page.SettingsDocument) {
      await this.readConfigurationSources(items, failures, page);
    }
    if (page === Page.Configuration || page === Page.PluginInventory) {
      await this.readPluginInventory(items, failures);
    }
    if (page === Page.Configuration || page === Page.AgentPresets) {
      await this.readAgentPresets(items, failures);
    }
    this.snapshot.items = items;
    this.snapshot.itemsPhase = failures.length > 0 && items.length === 0 ? LoadPhase.Failed : LoadPhase.Ready;
    if (failures.length > 0) {
      this.snapshot.failure = failures.join('；');
    }
  }

  /**
   * Read the real MCP registry through the phone-mcp Remote. The registry file
   * and mount state belong to the Worker; this host only displays them.
   */
  private async loadMcp(): Promise<void> {
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法读取 MCP 注册表');
      return;
    }
    try {
      const value = await this.pageBridge.call('phone/mcpList', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      if (root === null) {
        this.snapshot.itemsPhase = LoadPhase.Failed;
        this.snapshot.failure = this.uiCopy('phone/mcpList 没有返回注册表快照');
        return;
      }
      const readError = jsonString(root, 'error', '');
      if (readError.length > 0) {
        this.snapshot.items = [];
        this.snapshot.itemsPhase = LoadPhase.Failed;
        this.snapshot.failure = this.uiFill('MCP 注册表读取失败：{0}', [this.clean(readError)]);
        return;
      }
      if (root['servers'] === undefined) {
        this.snapshot.items = [];
        this.snapshot.itemsPhase = LoadPhase.Unknown;
        return;
      }
      const file = jsonString(root, 'file', '');
      const servers = asArray(root['servers']);
      const items: NamedItem[] = [];
      for (let index = 0; index < servers.length && items.length < 400; index++) {
        const row = asRecord(servers[index]);
        if (row === null) {
          continue;
        }
        const name = jsonString(row, 'serverName', jsonString(row, 'name', ''));
        if (name.length === 0) {
          continue;
        }
        const status = jsonString(row, 'status', 'unknown');
        const authentication = jsonString(row, 'authentication', 'none');
        const toolNames: string[] = [];
        const tools = asArray(row['tools']);
        for (let toolIndex = 0; toolIndex < tools.length && toolNames.length < 64; toolIndex++) {
          const tool = tools[toolIndex];
          if (typeof tool === 'string') {
            const toolName = tool as string;
            if (toolName.length > 0) {
              toolNames.push(toolName);
            }
          }
        }
        const url = jsonString(row, 'url', '');
        const error = jsonString(row, 'error', '');
        const item = new NamedItem();
        item.id = `mcp:${name}`;
        item.title = name;
        item.subtitle = `${status} · ${toolNames.length} 个工具 · ${authentication}`;
        item.enabled = status === 'connected';
        item.detail = `${file.length > 0 ? `${file} · ` : ''}${url}` +
          `${toolNames.length > 0 ? ` · ${toolNames.join(', ')}` : ''}` +
          `${error.length > 0 ? ` · 错误：${error}` : ''}`;
        items.push(item);
        const meta = new ItemMeta();
        meta.kind = 'mcp';
        meta.field = name;
        meta.title = name;
        this.itemMeta.set(item.id, meta);
      }
      this.snapshot.items = items;
      this.snapshot.itemsPhase = LoadPhase.Ready;
      this.snapshot.failure = '';
    } catch (error) {
      this.snapshot.items = [];
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiFill('MCP 注册表读取失败：{0}', [this.clean(errorText(error as Error))]);
    }
  }

  /**
   * Read the live phone-shell capability facts. The accelerators and mounts are
   * host-advertised measurements, never a local guess.
   */
  private async loadTools(): Promise<void> {
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法读取 shell 能力');
      return;
    }
    try {
      const value = await this.pageBridge.call('phone/shellCaps', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      if (root === null) {
        this.snapshot.itemsPhase = LoadPhase.Failed;
        this.snapshot.failure = this.uiCopy('phone/shellCaps 没有返回能力快照');
        return;
      }
      if (root['linked'] === undefined || root['accelerators'] === undefined) {
        this.snapshot.items = [];
        this.snapshot.itemsPhase = LoadPhase.Unknown;
        return;
      }
      const linked = jsonBool(root, 'linked', false);
      const transportSupported = jsonBool(root, 'transportSupported', false);
      const provider = jsonString(root, 'provider', '');
      const version = jsonString(root, 'version', '');
      const factsSource = jsonString(root, 'factsSource', '');
      const note = jsonString(root, 'note', '');
      const items: NamedItem[] = [];
      const status = new NamedItem();
      status.id = 'tools:status';
      status.title = linked ? 'shell 已链接' : 'shell 未链接';
      status.subtitle = `${provider.length > 0 ? provider : '宿主'}${version.length > 0 ? ` ${version}` : ''}` +
        `${transportSupported ? '' : ' · 传输不支持'}`;
      status.detail = `${note}${factsSource.length > 0 ? `（来源：${factsSource}）` : ''}`;
      status.enabled = linked;
      items.push(status);
      if (!transportSupported) {
        const transport = new NamedItem();
        transport.id = 'tools:transport';
        transport.title = '传输不可用';
        transport.subtitle = 'node-http 或未确认的通道';
        transport.detail = '宿主不会在此传输上执行命令；本页只读展示能力，不提供运行入口。';
        transport.enabled = false;
        items.push(transport);
      }
      const accelerators = asArray(root['accelerators']);
      for (let index = 0; index < accelerators.length && items.length < 400; index++) {
        const name = accelerators[index];
        if (typeof name !== 'string') {
          continue;
        }
        const accelerator = name as string;
        if (accelerator.length === 0) {
          continue;
        }
        const item = new NamedItem();
        item.id = `tools:accelerator:${accelerator}`;
        item.title = accelerator;
        item.subtitle = '只读加速器';
        item.detail = '宿主在 exec-bridge hello 中声明了它；选择它不会改写任何文件。';
        item.enabled = true;
        items.push(item);
      }
      if (root['mounts'] === undefined) {
        const unknownMounts = new NamedItem();
        unknownMounts.id = 'tools:mounts:unknown';
        unknownMounts.title = '挂载';
        unknownMounts.subtitle = '未知';
        unknownMounts.detail = '宿主这次没有发布挂载表；不伪造 / 挂载。';
        unknownMounts.enabled = false;
        items.push(unknownMounts);
      } else {
        const mounts = asArray(root['mounts']);
        for (let index = 0; index < mounts.length && items.length < 400; index++) {
          const row = asRecord(mounts[index]);
          if (row === null) {
            continue;
          }
          const hostPath = jsonString(row, 'hostPath', '');
          const guestPath = jsonString(row, 'guestPath', '');
          if (hostPath.length === 0 || guestPath.length === 0) {
            continue;
          }
          const item = new NamedItem();
          item.id = `tools:mount:${index}`;
          item.title = `${hostPath} → ${guestPath}`;
          item.subtitle = jsonBool(row, 'readOnly', true) ? '只读挂载' : '读写挂载';
          item.detail = '宿主 hello 报告的挂载；本页不创建、不修改挂载。';
          item.enabled = true;
          items.push(item);
        }
      }
      this.snapshot.items = items;
      this.snapshot.itemsPhase = LoadPhase.Ready;
      this.snapshot.failure = '';
    } catch (error) {
      this.snapshot.items = [];
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiFill('shell 能力读取失败：{0}', [this.clean(errorText(error as Error))]);
    }
  }

  /** Model routes the model-selection editor may offer; empty never means "all". */
  private async readModelChoices(failures: string[]): Promise<void> {
    try {
      const value = await this.pageBridge.call('session/modelCatalog', EMPTY_ARGS, 5000);
      const root = this.catalogRoot(value);
      if (root === null) {
        failures.push('模型目录读取失败：没有返回模型目录');
        return;
      }
      const options = modelOptionsFromCatalog(root);
      for (let index = 0; index < options.length; index++) {
        this.modelChoices.push(`${options[index].provider}/${options[index].model}`);
      }
    } catch (error) {
      failures.push(`模型目录读取失败：${this.clean(errorText(error as Error))}`);
    }
  }

  private async readConfigurationSources(items: NamedItem[], failures: string[], page: Page): Promise<void> {
    try {
      const value = await this.pageBridge.call('settings/describe', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      if (root === null) {
        failures.push('settings/describe 没有返回配置对象');
      } else {
        if (page === Page.SettingsDocument) {
          this.appendSettingsDocumentItems(items, root);
        } else {
          this.appendConfigItems(items, root);
        }
      }
    } catch (error) {
      failures.push(`设置读取失败：${this.clean(errorText(error as Error))}`);
    }
    if (page === Page.SettingsDocument) {
      return;
    }
    try {
      const value = await this.pageBridge.call('permissionPresets/catalog', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      const options = asArray(root === null ? null : root['defaultOptions']);
      for (let index = 0; index < options.length && items.length < 400; index++) {
        const row = asRecord(options[index]);
        if (row === null) {
          continue;
        }
        const id = jsonString(row, 'value', '');
        if (id.length === 0) {
          continue;
        }
        const item = new NamedItem();
        item.id = `permission:${id}`;
        item.title = jsonString(row, 'name', id);
        item.subtitle = id === jsonString(root, 'defaultPreset', '') ? '当前默认' : '权限模式';
        item.detail = jsonString(row, 'description', '');
        item.enabled = true;
        items.push(item);
        const meta = new ItemMeta();
        meta.kind = 'permission';
        meta.field = id;
        meta.title = item.title;
        this.itemMeta.set(item.id, meta);
      }
    } catch (error) {
      failures.push(`权限列表读取失败：${this.clean(errorText(error as Error))}`);
    }
  }

  private appendConfigItems(items: NamedItem[], root: Record<string, Object>): void {
    const writable = jsonBool(root, 'writable', false);
    const namespaces = asArray(root['namespaces']);
    for (let index = 0; index < namespaces.length; index++) {
      const nsRow = asRecord(namespaces[index]);
      if (nsRow === null) {
        continue;
      }
      const ns = jsonString(nsRow, 'ns', '');
      const revision = jsonNumber(nsRow, 'revision', -1);
      const value = asRecord(nsRow['value']);
      const schema = asRecord(nsRow['schema']);
      const properties = asRecord(schema === null ? null : schema['properties']);
      for (let specIndex = 0; specIndex < CONFIG_SPECS.length; specIndex++) {
        const spec = CONFIG_SPECS[specIndex];
        if (spec.ns !== ns || value === null || value[spec.field] === undefined) {
          continue;
        }
        const current = value[spec.field];
        const item = new NamedItem();
        item.id = `config:${ns}:${spec.field}`;
        item.title = `${ns} · ${spec.field}`;
        item.valueType = spec.type;
        item.subtitle = this.displayValue(current);
        const property = asRecord(properties === null ? null : properties[spec.field]);
        item.detail = property === null ? '' : jsonString(property, 'description', '');
        if (spec.type === 'modelSelection') {
          item.options = this.modelChoices.slice();
          item.selected = this.routeKeys(current);
          item.subtitle = item.selected.length > 0 ? item.selected.join(', ') : '未选择模型';
        }
        const selectable = spec.type !== 'modelSelection' || item.options.length > 0;
        item.enabled = writable && revision >= 0 && selectable;
        items.push(item);
        const meta = new ItemMeta();
        meta.kind = 'config';
        meta.ns = ns;
        meta.field = spec.field;
        meta.valueType = spec.type;
        meta.revision = revision;
        meta.title = item.title;
        meta.options = item.options.slice();
        this.itemMeta.set(item.id, meta);
      }
      if (ns === 'permission' && value !== null && value['defaultPreset'] !== undefined) {
        const item = new NamedItem();
        item.id = `permission:current:${jsonString(value, 'defaultPreset', '')}`;
        item.title = 'permission · defaultPreset';
        item.subtitle = jsonString(value, 'defaultPreset', '');
        item.enabled = false;
        items.push(item);
      }
    }
  }

  /** `allowedModels` is an array of exact {provider,model} routes, never bare strings. */
  private routeKeys(value: Object | null | undefined): string[] {
    const keys: string[] = [];
    const rows = asArray(value);
    for (let index = 0; index < rows.length; index++) {
      const row = asRecord(rows[index]);
      const provider = jsonString(row, 'provider', '');
      const model = jsonString(row, 'model', '');
      if (provider.length > 0 && model.length > 0) {
        keys.push(`${provider}/${model}`);
      }
    }
    return keys;
  }

  private appendSettingsDocumentItems(items: NamedItem[], root: Record<string, Object>): void {
    const namespaces = asArray(root['namespaces']);
    for (let index = 0; index < namespaces.length && items.length < 200; index++) {
      const row = asRecord(namespaces[index]);
      if (row === null) {
        continue;
      }
      const ns = jsonString(row, 'ns', '');
      if (ns.length === 0) {
        continue;
      }
      const item = new NamedItem();
      item.id = `settings:${ns}`;
      item.title = ns;
      item.subtitle = `revision ${jsonNumber(row, 'revision', -1)}`;
      item.detail = bounded(JSON.stringify(row['value'] === undefined ? {} : row['value']), 8000);
      item.enabled = jsonBool(root, 'writable', false);
      items.push(item);
      const meta = new ItemMeta();
      meta.kind = 'settingsDocument';
      meta.ns = ns;
      meta.revision = jsonNumber(row, 'revision', -1);
      this.itemMeta.set(item.id, meta);
    }
  }

  private async readPluginInventory(items: NamedItem[], failures: string[]): Promise<void> {
    try {
      const value = await this.pageBridge.call('pluginInventory/list', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      const entries = asArray(root === null ? null : root['entries']);
      for (let index = 0; index < entries.length && items.length < 400; index++) {
        const row = asRecord(entries[index]);
        if (row === null) {
          continue;
        }
        const entryId = jsonString(row, 'entryId', '');
        if (entryId.length === 0) {
          continue;
        }
        const item = new NamedItem();
        item.id = `plugin:${entryId}`;
        item.title = jsonString(row, 'moduleName', entryId);
        item.subtitle = jsonString(row, 'fiberPhase', jsonBool(row, 'enabled', true) ? 'enabled' : 'disabled');
        item.enabled = jsonBool(row, 'enabled', true);
        item.detail = `entry ${entryId}`;
        items.push(item);
        const meta = new ItemMeta();
        meta.kind = 'plugin';
        meta.field = entryId;
        meta.title = item.title;
        this.itemMeta.set(item.id, meta);
      }
    } catch (error) {
      failures.push(`插件清单读取失败：${this.clean(errorText(error as Error))}`);
    }
  }

  private async readAgentPresets(items: NamedItem[], failures: string[]): Promise<void> {
    try {
      const value = await this.pageBridge.call('agentPresets/list', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      const rows = asArray(root === null ? null : root['presets']);
      for (let index = 0; index < rows.length && items.length < 400; index++) {
        const row = asRecord(rows[index]);
        if (row === null) {
          continue;
        }
        const id = jsonString(row, 'id', '');
        if (id.length === 0) {
          continue;
        }
        const item = new NamedItem();
        item.id = `preset:${id}`;
        item.title = jsonString(row, 'name', jsonString(row, 'title', id));
        item.subtitle = jsonString(row, 'description', '');
        item.detail = `${jsonBool(row, 'isDefault', false) ? '默认预设' : 'Agent 预设'}${jsonBool(row, 'custom', false) ? ' · 自定义' : ''}`;
        item.enabled = jsonString(row, 'broken', '').length === 0;
        items.push(item);
        const meta = new ItemMeta();
        meta.kind = 'preset';
        meta.field = id;
        meta.title = item.title;
        this.itemMeta.set(item.id, meta);
      }
    } catch (error) {
      failures.push(`Agent 预设读取失败：${this.clean(errorText(error as Error))}`);
    }
  }

  private async loadAutomation(): Promise<void> {
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法读取定时任务');
      return;
    }
    try {
      const value = await this.pageBridge.call('schedule/catalog', EMPTY_ARGS, 5000);
      const root = this.remoteValue(asRecord(value));
      let rows = asArray(value);
      if (rows.length === 0 && root !== null) {
        rows = asArray(root['records']);
        if (rows.length === 0) {
          rows = asArray(root['schedules']);
        }
      }
      const items: NamedItem[] = [];
      for (let index = 0; index < rows.length && items.length < 400; index++) {
        const row = asRecord(rows[index]);
        if (row === null) {
          continue;
        }
        const id = jsonString(row, 'id', '');
        if (id.length === 0) {
          continue;
        }
        const record = this.automationRecordOf(row);
        this.automationRecords.set(id, record);
        const item = new NamedItem();
        item.id = `automation:${id}`;
        item.valueType = 'automation';
        item.title = record.title.length > 0 ? record.title : '定时任务';
        item.subtitle = `${record.status.length > 0 ? record.status : 'unknown'} · ${this.automationTimingLabel(record)}`;
        item.detail = record.detail;
        item.enabled = record.status === 'active';
        items.push(item);
        const meta = new ItemMeta();
        meta.kind = 'automation';
        meta.field = id;
        meta.title = item.title;
        this.itemMeta.set(item.id, meta);
      }
      this.snapshot.items = items;
      this.snapshot.itemsPhase = LoadPhase.Ready;
    } catch (error) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiFill('定时任务读取失败：{0}', [this.clean(errorText(error as Error))]);
    }
  }

  private automationRecordOf(row: Record<string, Object>): AutomationSchedule {
    const record = new AutomationSchedule();
    record.id = jsonString(row, 'id', '');
    record.title = jsonString(row, 'title', '');
    record.prompt = jsonString(row, 'prompt', '');
    record.kind = jsonString(row, 'kind', '');
    record.status = jsonString(row, 'status', '');
    record.scheduledAt = this.scalarText(row, 'scheduledAt');
    record.afterSeconds = this.scalarText(row, 'afterSeconds');
    record.everySeconds = this.scalarText(row, 'everySeconds');
    record.time = this.scalarText(row, 'time');
    record.timeZone = this.scalarText(row, 'timeZone');
    record.expression = this.scalarText(row, 'expression');
    record.weekdays = this.weekdayText(row['weekdays']);
    record.detail = JSON.stringify(row);
    record.updatedAt = typeof row['updatedAt'] === 'string' ? row['updatedAt'] as string : null;
    return record;
  }

  private scalarText(row: Record<string, Object> | null, key: string): string {
    const value: Object | undefined = row === null ? undefined : row[key];
    if (typeof value === 'string') {
      return value as string;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return '';
  }

  private weekdayText(value: Object | undefined): string {
    const rows = asArray(value);
    const days: string[] = [];
    for (let index = 0; index < rows.length; index++) {
      const day = rows[index];
      if (typeof day === 'number') {
        days.push(String(day));
      }
    }
    return days.join(',');
  }

  private automationTimingLabel(record: AutomationSchedule): string {
    if (record.kind === 'after') {
      return `after ${record.afterSeconds}s`;
    }
    if (record.kind === 'every') {
      return `every ${record.everySeconds}s`;
    }
    if (record.kind === 'daily' || record.kind === 'weekly') {
      return record.weekdays.length > 0 ? `${record.time} ${record.timeZone} (${record.weekdays})` :
        `${record.time} ${record.timeZone}`;
    }
    if (record.kind === 'cron') {
      return record.expression;
    }
    return record.scheduledAt;
  }

  private async loadFiles(): Promise<void> {
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.filesPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法读取文件');
      return;
    }
    try {
      const value = await this.pageBridge.callListFiles(this.snapshot.filePath);
      this.snapshot.files = this.filesFrom(value);
      this.snapshot.filesPhase = LoadPhase.Ready;
    } catch (error) {
      this.snapshot.filesPhase = LoadPhase.Failed;
      this.snapshot.files = [];
      this.snapshot.failure = this.uiFill('文件列表读取失败：{0}', [this.clean(errorText(error as Error))]);
    }
  }

  private filesFrom(value: Object): FileEntry[] {
    const rows = asArray(value);
    const files: FileEntry[] = [];
    for (let index = 0; index < rows.length && files.length < 2000; index++) {
      const row = asRecord(rows[index]);
      if (row === null) {
        continue;
      }
      const entry = new FileEntry();
      entry.name = jsonString(row, 'name', '');
      entry.path = jsonString(row, 'path', '');
      entry.directory = jsonBool(row, 'directory', false);
      entry.size = jsonNumber(row, 'size', 0);
      entry.modifiedAt = jsonNumber(row, 'modifiedAt', 0);
      if (entry.name.length === 0 || entry.path.length === 0) {
        continue;
      }
      files.push(entry);
    }
    files.sort((left: FileEntry, right: FileEntry): number => {
      if (left.directory !== right.directory) {
        return left.directory ? -1 : 1;
      }
      if (left.name === right.name) {
        return 0;
      }
      return left.name < right.name ? -1 : 1;
    });
    return files;
  }

  private async loadPreview(): Promise<void> {
    if (this.snapshot.previewPath.length === 0) {
      this.snapshot.itemsPhase = LoadPhase.Ready;
      return;
    }
    if (isImagePath(this.snapshot.previewPath) ||
      this.snapshot.previewPath.startsWith('http://') ||
      this.snapshot.previewPath.startsWith('https://')) {
      // Binary image preview; the component loads bytes via loadImage. Do not
      // run $readFile (which would decode the image as UTF-8 text).
      this.snapshot.previewText = '';
      this.snapshot.filesPhase = LoadPhase.Ready;
      return;
    }
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.filesPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法预览文件');
      return;
    }
    try {
      const value = await this.pageBridge.callReadFile(this.snapshot.previewPath);
      const row = asRecord(value);
      this.snapshot.previewText = bounded(jsonString(row, 'text', ''), 1024 * 1024);
      this.snapshot.filesPhase = LoadPhase.Ready;
    } catch (error) {
      this.snapshot.previewText = '';
      this.snapshot.filesPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiFill('预览读取失败：{0}', [this.clean(errorText(error as Error))]);
    }
  }

  /**
   * Read-only network-policy facts for the active model edge.
   *
   * The legacy `settings.egressHosts` list is not consumed by HostHttpProxy, so
   * this page must never present it as an active allowlist. The only facts we
   * can measure here are the frozen boot profile, whether the local engine is
   * running, and the fixed rules the proxy and image reader actually enforce.
   * No request is sent and no credential value is read.
   */
  private loadForPageEgress(): void {
    const items: NamedItem[] = [];
    const active: ProviderProfileRecord | null = this.nativeRunning ? this.bootProvider : null;

    let origin: string = '';
    let originUsable: boolean = false;
    if (active !== null) {
      const raw: string = active.baseUrl.trim();
      if (raw.toLowerCase().startsWith('https://')) {
        let authority: string = raw.substring(8);
        const delimiters: string = '/?#';
        let end: number = authority.length;
        for (let index: number = 0; index < delimiters.length; index++) {
          const at: number = authority.indexOf(delimiters.charAt(index));
          if (at >= 0 && at < end) { end = at; }
        }
        authority = authority.substring(0, end);
        if (authority.length > 0 && authority.indexOf('@') < 0 &&
          authority.indexOf(' ') < 0 && authority.indexOf('\t') < 0 &&
          authority.indexOf('\\') < 0) {
          origin = `https://${authority}`;
          originUsable = true;
        }
      }
    }

    const route = new NamedItem();
    route.id = 'egress:route';
    route.title = this.uiCopy('当前模型路由');
    if (!this.nativeRunning) {
      route.subtitle = this.uiCopy('未知（本地引擎未运行）');
      route.detail = this.uiCopy('本地引擎未运行，没有活动路由可读取。这是未测量，不是出网被拒绝。');
    } else if (active === null) {
      route.subtitle = this.uiCopy('无活动模型服务');
      route.detail = this.uiCopy('本地引擎正在运行，但启动时没有模型服务；模型请求没有可转发的目标。');
    } else if (originUsable) {
      route.subtitle = this.uiCopy('仅一个活动模型服务');
      route.detail = this.uiFill('只转发到 {0} 的模型协议路径；不会转发到其他主机或路径。', [origin]);
    } else {
      route.subtitle = this.uiCopy('启动记录不可用');
      route.detail = this.uiCopy('启动记录里的模型服务地址不是可用的 https 地址；模型请求会被拒绝。');
    }
    route.enabled = false;
    items.push(route);

    const paths = new NamedItem();
    paths.id = 'egress:paths';
    paths.title = this.uiCopy('放行的模型路径');
    paths.subtitle = this.uiCopy('模型协议路径 + 官方工具路径');
    paths.detail = this.uiCopy('路径范围由当前模型服务的基地址和 HostHttpProxy 的模型协议表决定；官方 DeepSeek 模型服务在启动放行时另加 /v1/tools/search 与 /v1/tools/fetch 两条 POST。其余路径拒绝，不改道、不跟随重定向。');
    paths.enabled = false;
    items.push(paths);

    const others = new NamedItem();
    others.id = 'egress:worker';
    others.title = this.uiCopy('其他 Worker 出网');
    others.subtitle = this.uiCopy('除官方工具外默认拒绝');
    others.detail = this.uiCopy('没有通用白名单或 MCP 出网授权；官方 Search/Fetch 仅按上述精确路径复用模型密钥，Worker 不能把宿主密钥带到其他主机。');
    others.enabled = false;
    items.push(others);

    const transport = new NamedItem();
    transport.id = 'egress:transport';
    transport.title = this.uiCopy('传输与密钥');
    transport.subtitle = this.uiCopy('仅 HTTPS；宿主逐请求注入');
    transport.detail = this.uiCopy('只接受 https；宿主每次模型请求从该服务的 AssetStore 别名读取密钥并注入；请求方自带的凭证头会被丢弃，重定向会被拒绝。');
    transport.enabled = false;
    items.push(transport);

    const image = new NamedItem();
    image.id = 'egress:image';
    image.title = this.uiCopy('Markdown 远程图片');
    image.subtitle = this.uiCopy('UI 独立读取');
    image.detail = this.uiCopy('http(s) 图片由界面直接读取，不经过模型代理、不带模型密钥；上限 8 MiB，最多 3 次已验证重定向，拒绝带用户信息的地址。');
    image.enabled = false;
    items.push(image);

    const test = new NamedItem();
    test.id = 'egress:test';
    test.title = this.uiCopy('连接测试');
    test.subtitle = this.uiCopy('仅显式发起');
    test.detail = this.uiCopy('只在模型服务页点击测试时读取该服务已保存的密钥并请求该服务；本页不探测远端是否可达，也不报告可达。');
    test.enabled = false;
    items.push(test);

    const legacy = new NamedItem();
    legacy.id = 'egress:legacy';
    legacy.title = this.uiCopy('旧 egressHosts 配置');
    legacy.subtitle = this.uiCopy('不参与本宿主出网');
    legacy.detail = this.uiCopy('本宿主不把 settings.egressHosts 当作生效白名单；旧配置既不放行也不拒绝任何请求。');
    legacy.enabled = false;
    items.push(legacy);

    const platform = new NamedItem();
    platform.id = 'egress:platform';
    platform.title = this.uiCopy('与 Android 的差异');
    platform.subtitle = this.uiCopy('没有可写的通用白名单');
    platform.detail = this.uiCopy('Android 有 allowedUpstreamHosts 和 MCP 精确授权；本宿主没有可写的 HostGrant API，也不显示伪造的白名单。');
    platform.enabled = false;
    items.push(platform);

    this.snapshot.items = items;
    this.snapshot.itemsPhase = this.nativeRunning ? LoadPhase.Ready : LoadPhase.Unknown;
    this.snapshot.failure = '';
  }

  private loadRuntime(): void {
    const items: NamedItem[] = [];
    if (this.nativeRunning) {
      try {
        const statusText: string = native.status();
        const status = parseJsonObject(statusText);
        this.snapshot.runtimeDetail = status === null ? statusText : JSON.stringify(status);
        if (status !== null) {
          const keys = Object.keys(status);
          for (let index = 0; index < keys.length; index++) {
            const key = keys[index];
            if (key === 'token' || key.toLowerCase().includes('secret')) {
              continue;
            }
            const item = new NamedItem();
            item.id = `runtime:${key}`;
            item.title = key;
            item.subtitle = this.displayValue(status[key]);
            item.enabled = false;
            items.push(item);
          }
        }
      } catch (error) {
        this.snapshot.failure = this.uiCopy('本地运行时状态读取失败');
      }
    } else {
      this.snapshot.runtimeDetail = this.uiCopy('本地运行时已停止');
    }
    const background = new NamedItem();
    background.id = 'runtime:background';
    background.title = '后台常驻';
    background.subtitle = '未实现';
    background.detail = 'HarmonyOS 宿主未实现后台常驻；系统可能在后台回收运行时。';
    background.enabled = false;
    items.push(background);
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
  }

  private async loadProbes(): Promise<void> {
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，无法运行诊断');
      return;
    }
    try {
      const value = await this.pageBridge.call('$diagnose', EMPTY_ARGS, 15000);
      const row = asRecord(value);
      const items: NamedItem[] = [];
      const keys = row === null ? [] : Object.keys(row);
      for (let index = 0; index < keys.length; index++) {
        const item = new NamedItem();
        item.id = `probe:${keys[index]}`;
        item.title = keys[index];
        item.subtitle = this.displayValue(row === null ? null : row[keys[index]]);
        item.enabled = jsonBool(row, keys[index], false);
        items.push(item);
      }
      this.snapshot.items = items;
      this.snapshot.itemsPhase = LoadPhase.Ready;
    } catch (error) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiFill('诊断失败：{0}', [this.clean(errorText(error as Error))]);
    }
  }

  private loadUnsupportedFacts(): void {
    const items: NamedItem[] = [];
    const rows: string[][] = [
      ['Ubuntu / proot', '不可用', 'HarmonyOS 原生宿主没有 proot；不会伪造 Ubuntu 运行成功。'],
      ['真机连接器', '未实现', '本版本没有外部设备连接器；不会显示在线设备。'],
      ['后台常驻', '未实现', '未声明后台连续运行；系统可能回收 Worker。'],
      ['Android 专属权限', '不适用', 'Android 的权限来源与 HarmonyOS 不同，未知状态不会显示为已授权。']
    ];
    for (let index = 0; index < rows.length; index++) {
      const item = new NamedItem();
      item.id = `unsupported:${index}`;
      item.title = rows[index][0];
      item.subtitle = rows[index][1];
      item.detail = rows[index][2];
      item.enabled = false;
      items.push(item);
    }
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
  }

  private loadArchivedSessions(): void {
    const items: NamedItem[] = [];
    for (let index = 0; index < this.snapshot.sessions.length; index++) {
      const session = this.snapshot.sessions[index];
      if (!session.archived) {
        continue;
      }
      const item = new NamedItem();
      item.id = `session:${session.id}`;
      item.title = session.title;
      item.subtitle = `${session.rows.length} 行`;
      item.detail = '已归档';
      item.enabled = true;
      items.push(item);
    }
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
  }

  private loadFontSizes(): void {
    const sizes: number[] = [14, 16, 18, 20];
    const items: NamedItem[] = [];
    for (let index = 0; index < sizes.length; index++) {
      const item = new NamedItem();
      item.id = `fontSize:${sizes[index]}`;
      item.title = `${sizes[index]}`;
      item.subtitle = sizes[index] === this.snapshot.settings.fontSize ? '当前' : '';
      item.enabled = true;
      items.push(item);
      const meta = new ItemMeta();
      meta.kind = 'fontSize';
      meta.field = String(sizes[index]);
      this.itemMeta.set(item.id, meta);
    }
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
  }

  private loadShortcuts(): void {
    const items: NamedItem[] = [];
    const labels: string[] = ['发送', '停止', '新会话', '打开设置'];
    const keys: string[] = ['Enter', 'Escape', 'Ctrl+N', 'Ctrl+,'];
    for (let index = 0; index < labels.length; index++) {
      const item = new NamedItem();
      item.id = `shortcut:${index}`;
      item.title = labels[index];
      item.subtitle = keys[index];
      item.detail = '快捷键由 ArkUI 宿主处理。';
      item.enabled = false;
      items.push(item);
    }
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
  }

  private licenseSources(): LicenseSource[] {
    const sources: LicenseSource[] = [];
    const phone = new LicenseSource();
    phone.id = 'license:mit';
    phone.title = 'Phone DSH';
    phone.subtitle = 'MIT';
    phone.files = ['licenses/phone-dsh-MIT.txt'];
    sources.push(phone);

    const ratex = new LicenseSource();
    ratex.id = 'license:ratex';
    ratex.title = 'RaTeX 0.1.15';
    ratex.subtitle = 'MIT';
    ratex.files = ['licenses/ratex-LICENSE.txt'];
    sources.push(ratex);

    const katex = new LicenseSource();
    katex.id = 'license:katex-fonts';
    katex.title = 'KaTeX fonts';
    katex.subtitle = 'SIL OFL 1.1';
    katex.files = [
      'licenses/katex-fonts-NOTICE.txt',
      'licenses/ratex-THIRD_PARTY_NOTICES.txt',
      'licenses/katex-fonts-OFL-1.1.txt'
    ];
    sources.push(katex);
    return sources;
  }

  /**
   * Read the bundled license texts from this HAP's rawfile resources. The list
   * is fixed and typed; every row is published even when its text cannot be
   * read, so a failed read never looks like an empty dependency list.
   */
  private async loadLicenses(): Promise<void> {
    const sources: LicenseSource[] = this.licenseSources();
    const items: NamedItem[] = [];
    const failedTitles: string[] = [];
    const ctx = this.context;
    for (let index: number = 0; index < sources.length; index++) {
      const source = sources[index];
      const item = new NamedItem();
      item.id = source.id;
      item.title = source.title;
      item.subtitle = source.subtitle;
      item.enabled = false;
      if (ctx !== null) {
        const parts: string[] = [];
        let failed = false;
        for (let file: number = 0; file < source.files.length; file++) {
          try {
            const raw: Uint8Array = await ctx.resourceManager.getRawFileContent(source.files[file]);
            const text: string = decodeUtf8(raw);
            if (text.length === 0) {
              failed = true;
              break;
            }
            parts.push(text);
          } catch (error) {
            failed = true;
            break;
          }
        }
        if (!failed) {
          item.detail = parts.join('\n\n');
        }
      }
      if (item.detail.length === 0) {
        failedTitles.push(source.title);
      }
      items.push(item);
    }
    this.snapshot.items = items;
    if (failedTitles.length > 0) {
      this.snapshot.itemsPhase = LoadPhase.Failed;
      this.snapshot.failure = this.uiFill(
        '许可文本读取失败：{0}；这不代表没有第三方依赖。',
        [failedTitles.join('、')]
      );
    } else {
      this.snapshot.itemsPhase = LoadPhase.Ready;
      this.snapshot.failure = '';
    }
  }

  private loadAbout(page: Page): void {
    const items: NamedItem[] = [];
    const item = new NamedItem();
    item.id = 'about:host';
    item.title = 'phoneDSH';
    item.subtitle = '原生鸿蒙宿主';
    item.detail = '设备内 Worker 运行时；模型密钥只保存在 AssetStore。';
    item.enabled = false;
    items.push(item);
    if (page === Page.Licenses) {
      const license = new NamedItem();
      license.id = 'license:mit';
      license.title = 'MIT License';
      license.subtitle = 'phone-dsh';
      license.detail = '本项目以 MIT 许可证发布；第三方组件保留各自许可证。';
      license.enabled = false;
      items.push(license);
    }
    this.snapshot.items = items;
    this.snapshot.itemsPhase = LoadPhase.Ready;
  }

  // ------------------------------------------------------------ item writes

  private async saveConfigField(meta: ItemMeta, value: string): Promise<void> {
    let patchValue: Object;
    if (meta.valueType === 'boolean') {
      const raw = value.trim();
      if (raw !== 'true' && raw !== 'false') {
        await this.failItemWrite(this.uiCopy('开关值必须是 true 或 false'));
        return;
      }
      patchValue = raw === 'true';
    } else if (meta.valueType === 'number') {
      const raw = value.trim();
      const number = Number(raw);
      if (raw.length === 0 || !Number.isFinite(number)) {
        await this.failItemWrite(this.uiCopy('请输入有效数字'));
        return;
      }
      patchValue = number;
    } else if (meta.valueType === 'modelSelection') {
      const routes = this.configModelRoutes(value, meta.options);
      if (routes === null) {
        await this.failItemWrite(this.uiCopy('请选择当前模型目录中的模型'));
        return;
      }
      patchValue = routes;
    } else {
      await this.failItemWrite(this.uiCopy('这个配置项没有可用的写入类型'));
      return;
    }
    const patch: Record<string, Object> = {};
    patch[meta.field] = patchValue;
    const args: SettingsUpdateArgs = { ns: meta.ns, patch: patch };
    if (meta.revision >= 0) {
      args.expectedRevision = meta.revision;
    }
    try {
      await this.pageBridge.call('settings/update', args as Object, 5000);
    } catch (error) {
      await this.failItemWrite(this.uiFill('设置未保存：{0}', [this.clean(errorText(error as Error))]));
      return;
    }
    this.snapshot.notice = this.uiCopy('设置已保存');
    this.snapshot.failure = '';
    await this.loadForPage();
  }

  /** Rejects anything the model catalog did not offer; empty selections stay legal. */
  private configModelRoutes(value: string, options: string[]): Object[] | null {
    let parsed: Object;
    try {
      parsed = JSON.parse(value) as Object;
    } catch (error) {
      return null;
    }
    if (!Array.isArray(parsed)) {
      return null;
    }
    const rows = asArray(parsed);
    const routes: Object[] = [];
    const seen: string[] = [];
    for (let index = 0; index < rows.length; index++) {
      const row = asRecord(rows[index]);
      const provider = jsonString(row, 'provider', '');
      const model = jsonString(row, 'model', '');
      const key = `${provider}/${model}`;
      if (provider.length === 0 || model.length === 0 || options.indexOf(key) < 0) {
        return null;
      }
      if (seen.indexOf(key) < 0) {
        seen.push(key);
        const route: Record<string, Object> = {};
        route['provider'] = provider;
        route['model'] = model;
        routes.push(route as Object);
      }
    }
    return routes;
  }

  private async failItemWrite(message: string): Promise<void> {
    this.snapshot.notice = '';
    this.snapshot.failure = message;
    this.emit();
    throw new Error(message);
  }

  private async saveSettingsDocument(meta: ItemMeta, value: string): Promise<void> {
    let patch = parseJsonObject(value);
    if (patch === null) {
      this.snapshot.failure = this.uiCopy('设置文档必须是 JSON 对象');
      this.emit();
      return;
    }
    const args: SettingsUpdateArgs = { ns: meta.ns, patch: patch };
    if (meta.revision >= 0) {
      args.expectedRevision = meta.revision;
    }
    try {
      await this.pageBridge.call('settings/update', args as Object, 5000);
      this.snapshot.notice = this.uiCopy('设置文档已保存');
      await this.loadForPage();
    } catch (error) {
      this.snapshot.failure = this.uiFill('设置文档未保存：{0}', [this.clean(errorText(error as Error))]);
      this.emit();
    }
  }

  private async saveAutomation(meta: ItemMeta, value: string): Promise<void> {
    const draft = parseJsonObject(value);
    if (draft === null) {
      await this.failItemWrite(this.uiCopy('定时任务内容必须是 JSON 对象'));
      return;
    }
    const title = jsonString(draft, 'title', '').trim();
    const prompt = jsonString(draft, 'prompt', '').trim();
    if (title.length === 0 || title.length > 120) {
      await this.failItemWrite(this.uiCopy('任务名称不能为空且最多 120 个字符'));
      return;
    }
    if (prompt.length === 0) {
      await this.failItemWrite(this.uiCopy('提醒内容不能为空'));
      return;
    }
    if (meta.field.length === 0) {
      await this.createAutomation(draft, title, prompt);
      return;
    }
    const record = this.automationRecords.get(meta.field);
    if (record === undefined) {
      await this.failItemWrite(this.uiCopy('定时任务已不存在，请刷新后重试'));
      return;
    }
    const patch: Record<string, Object> = { title: title, prompt: prompt };
    const request: Record<string, Object> = { id: record.id, action: 'update', patch: patch };
    request['expectedUpdatedAt'] = record.updatedAt as Object;
    if (jsonBool(draft, 'changeTiming', false)) {
      const change = this.automationTiming(draft, true);
      if (change === null) {
        await this.failItemWrite(this.uiCopy('请填写完整有效的重复规则'));
        return;
      }
      patch['timing'] = change as Object;
    }
    let result: Record<string, Object> | null = null;

    try {
      result = this.remoteValue(asRecord(
        await this.pageBridge.call('schedule/edit', new RequestWrapper(request), 15000)));
    } catch (error) {
      await this.failItemWrite(this.uiFill('定时任务未保存：{0}', [this.clean(errorText(error as Error))]));
      return;
    }
    if (result !== null && jsonString(result, 'code', '').length > 0) {
      const code = jsonString(result, 'code', '');
      const reason = code === 'schedule_conflict' ? this.uiCopy('任务已被其他窗口修改') :
        code === 'schedule_ended' ? this.uiCopy('任务已结束') : this.uiCopy('任务已不存在');
      await this.failItemWrite(this.uiFill('{0}，请刷新后重试', [reason]));
      return;
    }
    if (result === null || jsonString(result, 'id', '') !== record.id) {
      await this.failItemWrite(this.uiCopy('保存请求已返回，但目录没有显示更新后的内容；请刷新确认。'));
      return;
    }
    await this.loadForPage();
    const saved = this.automationRecords.get(record.id);
    if (saved === undefined || saved.title !== title || saved.prompt !== prompt) {
      await this.failItemWrite(this.uiCopy('保存请求已返回，但目录没有显示更新后的内容；请刷新确认。'));
      return;
    }
    this.snapshot.notice = this.uiCopy('定时任务已更新。');
    this.snapshot.failure = '';
    this.emit();
  }

  private async createAutomation(draft: Record<string, Object>, title: string, prompt: string): Promise<void> {
    const session = this.activeSession();
    const sessionId = session === null ? '' : session.workerSessionId;
    if (sessionId.length === 0) {
      await this.failItemWrite(this.uiCopy('当前会话尚未启动 Worker，无法创建定时任务'));
      return;
    }
    const selector = this.automationTiming(draft, false);
    if (selector === null) {
      await this.failItemWrite(this.uiCopy('请填写完整有效的重复规则'));
      return;
    }
    const request: Record<string, Object> = {};
    request['sessionId'] = sessionId;
    request['title'] = title;
    request['prompt'] = prompt;
    const keys = Object.keys(selector);
    for (let index = 0; index < keys.length; index++) {
      request[keys[index]] = selector[keys[index]];
    }
    let created: Record<string, Object> | null = null;
    try {
      created = this.remoteValue(asRecord(await this.pageBridge.call(
        'phone/createSchedule', new RequestWrapper(request), 15000)));
    } catch (error) {
      await this.failItemWrite(this.uiFill('定时任务未保存：{0}', [this.clean(errorText(error as Error))]));
      return;
    }
    const id = jsonString(created, 'id', '');
    if (id.length === 0) {
      await this.failItemWrite(this.uiCopy('创建请求没有返回定时任务 id'));
      return;
    }
    await this.loadForPage();
    if (!this.automationRecords.has(id)) {
      await this.failItemWrite(this.uiCopy('创建请求已返回，但目录没有显示新任务；请刷新确认。'));
      return;
    }
    this.snapshot.notice = this.uiCopy('定时任务已创建。');
    this.snapshot.failure = '';
    this.emit();
  }

  /**
   * Build the existing schedule selector fields. Create flattens the selector
   * (`after_seconds`/`at`/`every_seconds`/daily/weekly/cron); update carries a
   * `change` whose one-shot kind is always `at`.
   */
  private automationTiming(draft: Record<string, Object>, editing: boolean): Record<string, Object> | null {
    const rule = jsonString(draft, 'rule', '');
    const map: Record<string, Object> = {};
    if (editing) {
      map['kind'] = rule === 'after' ? 'at' : rule;
    }
    if (rule === 'after') {
      const seconds = Number(jsonString(draft, 'afterSeconds', ''));
      if (!Number.isFinite(seconds) || seconds <= 0) {
        return null;
      }
      if (editing) {
        map['at'] = new Date(Date.now() + seconds * 1000).toISOString();
      } else {
        map['after_seconds'] = seconds;
      }
      return map;
    }
    if (rule === 'at') {
      const at = jsonString(draft, 'at', '').trim();
      if (at.length === 0) {
        return null;
      }
      map['at'] = at;
      return map;
    }
    if (rule === 'every') {
      const seconds = Number(jsonString(draft, 'everySeconds', ''));
      if (!Number.isFinite(seconds) || seconds <= 0) {
        return null;
      }
      map['every_seconds'] = seconds;
      return map;
    }
    const time = jsonString(draft, 'time', '').trim();
    const timeZone = jsonString(draft, 'timeZone', '').trim();
    if (time.length === 0 || timeZone.length === 0) {
      return null;
    }
    if (rule === 'daily' || rule === 'weekly') {
      const group: Record<string, Object> = {};
      group['time'] = time;
      group['time_zone'] = timeZone;
      if (rule === 'weekly') {
        const weekdays = this.automationWeekdays(jsonString(draft, 'weekdays', ''));
        if (weekdays === null) {
          return null;
        }
        group['weekdays'] = weekdays as Object;
      }
      map[rule] = group as Object;
      return map;
    }
    if (rule === 'cron') {
      const expression = jsonString(draft, 'expression', '').trim();
      if (expression.length === 0) {
        return null;
      }
      const cron: Record<string, Object> = {};
      cron['expression'] = expression;
      cron['time_zone'] = timeZone;
      map['cron'] = cron as Object;
      return map;
    }
    return null;
  }

  private automationWeekdays(raw: string): number[] | null {
    const parts = raw.split(',');
    const days: number[] = [];
    for (let index = 0; index < parts.length; index++) {
      const text = parts[index].trim();
      if (text.length === 0) {
        continue;
      }
      const day = Number(text);
      if (!Number.isInteger(day) || day < 1 || day > 7 || days.indexOf(day) >= 0) {
        return null;
      }
      days.push(day);
    }
    return days.length > 0 ? days : null;
  }

  private async activatePreset(meta: ItemMeta, value: string): Promise<void> {
    if (value === 'use') {
      if (this.snapshot.running) {
        this.snapshot.notice = this.uiCopy('本轮仍在运行；停止后才能使用预设开新会话。');
        this.emit();
        return;
      }
      const request: SessionCreateRequest = { cwd: '/dsh/workspace', agentPreset: meta.field };
      const args: SessionCreateArgs = { request: request };
      try {
        const callValue = await this.pageBridge.call('session/create', args as Object, 30000);
        const row = asRecord(callValue);
        const workerId = jsonString(row, 'sessionId', '');
        if (workerId.length === 0) {
          throw new Error('session/create 没有返回 sessionId');
        }
        const session = this.createLocalSession(meta.title, this.snapshot.activeFolderId);
        session.workerSessionId = workerId;
        this.resetNavigation();
        const outcome = this.persistChatsOutcome();
        if (!outcome.ok) {
          this.lastPersistError = outcome.error;
          this.snapshot.failure = outcome.error;
          this.emit();
          return;
        }
        this.snapshot.notice = this.uiFill('已用预设 {0} 创建新会话。', [meta.title]);
        this.emit();
      } catch (error) {
        this.snapshot.failure = this.uiFill('预设会话未创建：{0}', [this.clean(errorText(error as Error))]);
        this.emit();
      }
      return;
    }
    try {
      const args: Record<string, Object> = {};
      args['agentPreset'] = meta.field;
      const value = await this.pageBridge.call('agentPresets/read', args as Object, 5000);
      const row = asRecord(value);
      this.snapshot.detail = bounded(jsonString(row, 'content', ''), 100000);
      this.snapshot.notice = this.uiCopy('已读取预设文档。');
      this.snapshot.failure = '';
    } catch (error) {
      this.snapshot.failure = this.uiFill('预设文档读取失败：{0}', [this.clean(errorText(error as Error))]);
    }
    this.emit();
  }

  private async deleteWorkerFile(path: string): Promise<void> {
    if (!path.startsWith('/dsh/') && !path.startsWith('/tmp/')) {
      this.snapshot.failure = this.uiCopy('拒绝删除 Worker 命名空间之外的文件');
      this.emit();
      return;
    }
    if (!await this.ensureRpcReady(10000)) {
      this.snapshot.failure = this.uiCopy('本地运行时尚未就绪，未删除文件');
      this.emit();
      return;
    }
    const command = `rm -f -- ${this.shellQuote(path)}`;
    try {
      await this.pageBridge.callCommand(command, '/dsh/workspace');
      this.snapshot.notice = this.uiCopy('文件已删除。');
      await this.loadFiles();
    } catch (error) {
      this.snapshot.failure = this.uiFill('删除失败：{0}', [this.clean(errorText(error as Error))]);
    }
    this.emit();
  }

  private shellQuote(value: string): string {
    return `'${value.split("'").join("'\\''")}'`;
  }

  // --------------------------------------------------------------- helpers

  private activeSession(): SessionRecord | null {
    return this.findSession(this.snapshot.activeSessionId);
  }

  private findSession(id: string): SessionRecord | null {
    if (id.length === 0) {
      return null;
    }
    for (let index = 0; index < this.snapshot.sessions.length; index++) {
      if (this.snapshot.sessions[index].id === id) {
        return this.snapshot.sessions[index];
      }
    }
    return null;
  }

  private createLocalSession(title: string, folderId?: string): SessionRecord {
    const session = new SessionRecord();
    session.id = uniqueId('chat');
    session.title = title;
    session.folderId = folderId !== undefined && folderId.length > 0 ? folderId : this.snapshot.activeFolderId;
    session.updatedAt = Date.now();
    session.rows = [];
    this.snapshot.sessions.unshift(session);
    this.snapshot.activeSessionId = session.id;
    this.snapshot.title = title;
    this.snapshot.rows = [];
    this.snapshot.draft = '';
    this.drafts.set(session.id, '');
    this.sortSessions();
    return session;
  }

  private selectFallbackSession(): void {
    this.clearVisiblePending();
    this.snapshot.activeSessionId = '';
    this.snapshot.rows = [];
    this.snapshot.title = '新会话';
    this.snapshot.draft = '';
    for (let index = 0; index < this.snapshot.sessions.length; index++) {
      const session = this.snapshot.sessions[index];
      if (!session.archived) {
        this.snapshot.activeSessionId = session.id;
        this.snapshot.title = session.title;
        this.snapshot.rows = this.cloneRows(session.rows);
        const draft = this.drafts.get(session.id);
        this.snapshot.draft = draft === undefined ? '' : draft;
        return;
      }
    }
  }

  private sortSessions(): void {
    this.snapshot.sessions.sort((left: SessionRecord, right: SessionRecord): number => {
      if (left.archived !== right.archived) {
        return left.archived ? 1 : -1;
      }
      if (left.pinned !== right.pinned) {
        return left.pinned ? -1 : 1;
      }
      return right.updatedAt - left.updatedAt;
    });
  }

  private titleFor(prompt: string): string {
    const first = prompt.split('\n')[0].trim();
    if (first.length === 0) {
      return '新会话';
    }
    return first.length > 24 ? first.substring(0, 24) : first;
  }

  private withAttachments(prompt: string, attachments: string[]): string {
    if (attachments.length === 0) {
      return prompt;
    }
    let text = prompt;
    for (let index = 0; index < attachments.length; index++) {
      text += `\n\n[附件] ${attachments[index]}`;
    }
    return text;
  }

  private pendingTitle(body: Record<string, Object> | null, kind: string): string {
    if (body === null) {
      return kind === 'user-questions/request' ? '需要回答' : '需要授权';
    }
    const reason = jsonString(body, 'reason', '');
    if (reason.length > 0) {
      return reason;
    }
    const tool = jsonString(body, 'toolName', '');
    if (tool.length > 0) {
      return `允许 ${tool}？`;
    }
    const questions = asArray(body['questions']);
    if (questions.length > 0) {
      const first = asRecord(questions[0]);
      return jsonString(first, 'question', '需要回答');
    }
    return kind === 'user-questions/request' ? '需要回答' : '需要授权';
  }

  private pendingDetail(body: Record<string, Object> | null, kind: string): string {
    if (body === null) {
      return '';
    }
    if (kind === 'user-questions/request') {
      const questions = asArray(body['questions']);
      if (questions.length > 0) {
        const first = asRecord(questions[0]);
        return jsonString(first, 'detail', '');
      }
      return '';
    }
    return jsonString(body, 'reason', '');
  }

  private pendingChoices(body: Record<string, Object> | null, kind: string): string[] {
    if (kind !== 'user-questions/request' || body === null) {
      return ['允许一次', '拒绝'];
    }
    const questions = asArray(body['questions']);
    const first = questions.length > 0 ? asRecord(questions[0]) : null;
    const options = asArray(first === null ? null : first['options']);
    const choices: string[] = [];
    for (let index = 0; index < options.length; index++) {
      const option = asRecord(options[index]);
      const label = jsonString(option, 'label', '');
      if (label.length > 0) {
        choices.push(label);
      }
    }
    return choices;
  }

  private questionOutcome(meta: PendingMeta, answer: string): QuestionOutcome {
    return buildQuestionOutcome(parseQuestionItems(meta.body), answer);
  }

  /** Drops only the visible card; the responder stays live for Worker events. */
  private hidePending(id: string): void {
    const next: PendingRequest[] = [];
    for (let index = 0; index < this.snapshot.pending.length; index++) {
      if (this.snapshot.pending[index].id !== id) {
        next.push(this.snapshot.pending[index]);
      }
    }
    this.snapshot.pending = next;
  }

  /** A conversation or runtime switch must never show another session's card. */
  private clearVisiblePending(): void {
    if (this.snapshot.pending.length > 0) {
      this.snapshot.pending = [];
    }
  }

  private removePending(id: string): void {
    this.pendingMeta.delete(id);
    this.answeringRequests.delete(id);
    this.hidePending(id);
  }

  private async ensureRpcReady(timeoutMillis: number): Promise<boolean> {
    if (this.workerReady) {
      return true;
    }
    const deadline = Date.now() + timeoutMillis;
    while (Date.now() < deadline) {
      if (this.disposed) {
        return false;
      }
      if (this.workerReady) {
        return true;
      }
      if (this.snapshot.engine === EnginePhase.Failed || this.snapshot.engine === EnginePhase.Stopped) {
        return false;
      }
      await delay(200);
    }
    return this.workerReady;
  }

  private async readPicked(uri: string): Promise<string> {
    const stat = fileIo.statSync(uri);
    if (stat.isDirectory()) {
      throw new Error('不能导入文件夹');
    }
    if (stat.size > 16 * 1024 * 1024) {
      throw new Error('附件超过 16 MiB');
    }
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    let bytes: Uint8Array;
    try {
      const buffer = new ArrayBuffer(stat.size);
      const read = fileIo.readSync(file.fd, buffer);
      bytes = new Uint8Array(buffer, 0, read);
    } finally {
      fileIo.closeSync(file);
    }
    const name = `${Date.now()}-${this.safeName(baseName(uri))}`;
    const path = `/dsh/workspace/attachments/${name}`;
    await this.pageBridge.callWriteFile(path, encodeBase64(bytes));
    return path;
  }

  private async importPickedFile(uri: string): Promise<string> {
    return await this.readPicked(uri);
  }

  private async pickImages(): Promise<string[]> {
    if (this.context === null) {
      return [];
    }
    const photoPicker = new picker.PhotoViewPicker(this.context);
    const result = await photoPicker.select();
    return result.photoUris;
  }

  private async pickDocuments(): Promise<string[]> {
    if (this.context === null) {
      return [];
    }
    const documentPicker = new picker.DocumentViewPicker(this.context);
    return await documentPicker.select();
  }

  private transcriptMarkdown(): string {
    let text = `# ${this.snapshot.title}\n\n`;
    for (let index = 0; index < this.snapshot.rows.length; index++) {
      const row = this.snapshot.rows[index];
      if (row.kind === RowKind.User) {
        text += `## 用户\n\n${row.text}\n\n`;
      } else if (row.kind === RowKind.Assistant) {
        text += `## 助手\n\n${row.text}\n\n`;
      } else if (row.kind === RowKind.Thinking) {
        text += `## 思考\n\n${row.text}\n\n`;
      } else if (row.kind === RowKind.Tool) {
        text += `## 工具 ${row.tool}\n\n${row.detail}\n\n`;
      } else if (row.kind === RowKind.Error) {
        text += `## 错误\n\n${row.text}\n\n${row.detail}\n\n`;
      } else if (row.text.length > 0) {
        text += `${row.text}\n\n`;
      }
    }
    return text;
  }

  private safeName(value: string): string {
    let name = value.trim();
    name = name.replace(/[^A-Za-z0-9._-]/g, '_');
    if (name.length === 0) {
      return 'file';
    }
    return name.length > 80 ? name.substring(0, 80) : name;
  }

  private displayValue(value: Object | null | undefined): string {
    if (value === null || value === undefined) {
      return 'unknown';
    }
    if (typeof value === 'string') {
      return bounded(value as string, 400);
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return bounded(JSON.stringify(value), 400);
  }

  private remoteValue(root: Record<string, Object> | null): Record<string, Object> | null {
    if (root === null) {
      return null;
    }
    if (jsonBool(root, 'ok', false)) {
      return asRecord(root['value']);
    }
    return root;
  }

  private ensureDirectory(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (error) {
      fileIo.mkdirSync(path, true);
    }
  }

  private clean(message: string): string {
    return redact(message, this.runtimeToken);
  }

  // -------------------------------------------------------- persistence

  private chatDocument(): StoredChatDocument {
    const active = this.activeSession();
    if (active !== null) {
      active.rows = this.cloneRows(this.snapshot.rows);
      active.title = this.snapshot.title;
      if (this.snapshot.draft.length > 0) {
        this.drafts.set(active.id, this.snapshot.draft);
      } else {
        this.drafts.delete(active.id);
      }
    }
    const document = new StoredChatDocument();
    document.version = 2;
    document.activeSessionId = this.snapshot.activeSessionId;
    document.activeFolderId = this.snapshot.activeFolderId;
    document.sessions = this.snapshot.sessions;
    document.folders = this.snapshot.folders;
    for (const entry of this.drafts.entries()) {
      const draft = new DraftRecord();
      draft.sessionId = entry[0];
      draft.text = entry[1];
      if (draft.sessionId.length > 0 && draft.text.length > 0) {
        document.drafts.push(draft);
      }
    }
    return document;
  }

  private persistChatsOutcome(): PersistOutcome {
    if (this.persistence === null) {
      return new PersistOutcome('私有存储不可用');
    }
    try {
      return new PersistOutcome(this.persistence.saveChats(this.chatDocument()));
    } catch (error) {
      return new PersistOutcome('会话记录写入失败');
    }
  }

  private persistSettingsOutcome(settings: Settings): PersistOutcome {
    if (this.persistence === null) {
      return new PersistOutcome('私有存储不可用');
    }
    try {
      return new PersistOutcome(this.persistence.saveSettings(settings));
    } catch (error) {
      return new PersistOutcome('设置保存失败');
    }
  }

  private persistNow(): void {
    // Background persistence is best-effort: report a visible failure, never
    // throw from a timer/stream callback where no caller can catch it.
    const chatOutcome = this.persistChatsOutcome();
    const settingsOutcome = this.persistSettingsOutcome(this.snapshot.settings);
    const combined = chatOutcome.ok
      ? (settingsOutcome.ok ? '' : settingsOutcome.error)
      : chatOutcome.error;
    if (combined.length > 0 && combined !== this.lastPersistError) {
      this.lastPersistError = combined;
      this.snapshot.failure = combined;
    } else if (combined.length === 0) {
      this.lastPersistError = '';
    }
  }

  private persistSoon(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      this.persistNow();
    }, 450);
  }

  // ------------------------------------------------------------ emit/clone

  private systemDark: boolean = false;
  private barDark: boolean | undefined = undefined;

  setSystemDark(value: boolean): void {
    this.systemDark = value;
    this.emit();
  }

  /** Effective locale for host-owned static copy; user/model data never uses it. */
  private uiLanguage(): string {
    const setting: string = this.snapshot.settings.language;
    let tag: string = '';
    try {
      tag = i18n.System.getSystemLanguage();
    } catch (error) {
      tag = 'zh';
    }
    return LocaleText.resolve(setting, tag.length > 0 ? tag : 'zh');
  }

  /** Static host chrome only. Dynamic values must go through uiFill. */
  private uiCopy(chinese: string): string {
    return LocaleText.tr(this.uiLanguage(), chinese);
  }

  private uiFill(chineseTemplate: string, values: string[]): string {
    return LocaleText.fill(this.uiLanguage(), chineseTemplate, values);
  }

  private emit(): void {
    if (this.disposed) {
      return;
    }
    this.snapshot.dark = this.snapshot.settings.theme === 'dark' ||
      (this.snapshot.settings.theme === 'system' && this.systemDark);
    // Locale is a projection fact: publish the live choice and the resolved
    // language so pure UI copy can look up English without reading the
    // snapshot. This is the only locale side effect the host owns.
    const localeSetting: string = this.snapshot.settings.language;
    let systemTag: string = '';
    try {
      systemTag = i18n.System.getSystemLanguage();
    } catch (error) {
      systemTag = 'zh';
    }
    if (systemTag.length === 0) { systemTag = 'zh'; }
    AppStorage.setOrCreate('pdshSystemLanguage', systemTag);
    AppStorage.setOrCreate('pdshLocaleSetting', localeSetting);
    AppStorage.setOrCreate('pdshLocale', LocaleText.resolve(localeSetting, systemTag));
    if (this.context !== null && this.barDark !== this.snapshot.dark) {
      const dark: boolean = this.snapshot.dark;
      this.barDark = dark;
      window.getLastWindow(this.context).then((appWindow: window.Window): void => {
        appWindow.setWindowSystemBarProperties({
          statusBarColor: dark ? '#101012' : '#F7F7F7',
          statusBarContentColor: dark ? '#F2F2F2' : '#1A1A1A',
          navigationBarColor: dark ? '#101012' : '#F7F7F7',
          navigationBarContentColor: dark ? '#F2F2F2' : '#1A1A1A'
        }).catch((): void => { hilog.warn(0x1A21, 'PhoneDSH', 'System bar appearance update failed'); });
      }).catch((): void => { hilog.warn(0x1A21, 'PhoneDSH', 'Main window unavailable for appearance update'); });
    }
    this.snapshot.revision = this.snapshot.revision + 1;
    if (this.onChange !== undefined) {
      publishSnapshot(this.snapshot, this.onChange);
    }
  }



  private cloneProvider(source: ProviderConfig): ProviderConfig {
    return JSON.parse(JSON.stringify(source)) as ProviderConfig;
  }

  private cloneSettings(source: Settings): Settings {
    return detachedSettings(source);
  }

  private cloneRow(source: ChatRow): ChatRow {
    return JSON.parse(JSON.stringify(source)) as ChatRow;
  }

  private cloneRows(source: ChatRow[]): ChatRow[] {
    return JSON.parse(JSON.stringify(source)) as ChatRow[];
  }

  private cloneSessions(source: SessionRecord[]): SessionRecord[] {
    return JSON.parse(JSON.stringify(source)) as SessionRecord[];
  }

  private cloneFolders(source: Workspace[]): Workspace[] {
    return JSON.parse(JSON.stringify(source)) as Workspace[];
  }






}
