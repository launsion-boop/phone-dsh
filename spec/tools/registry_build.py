#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reproduce spec/registry.json from baseline sections 3/4 and reviewed path expansions.

The Markdown source cells, owner roles and trigger predicates are read from the
baseline. Short/qualified implementation names require the explicit projection
metadata below. Update that reviewed metadata when changing a row's path meaning
or adding/removing an ID; never infer implemented status from normative prose.
The current registry and external evidence files are NOT generation inputs.
"""
import argparse
import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from registry_check import SpecError, baseline_tables, baseline_triggers, validate_json

# Reviewed expansions of the abbreviated paths/language groupings in section 3.
# These are source metadata, not a cached copy of the generated registry.
PATH_PROJECTIONS = {'P01': {'authority': ['spec/v1/channel.md', 'spec/v1/schema', 'spec/v1/golden/frames'],
         'ends': {'Swift': ['Sources/PhoneDSHWire',
                            'Sources/PhoneDSHLoopback/ChannelServer.swift',
                            'Sources/PhoneDSH/PhoneDSHChannel.swift'],
                  'TypeScript': ['plugins/channel/src'],
                  'Rust': ['shell/crates/pdsh-wire', 'shell/crates/pdsh-jni'],
                  'Kotlin': ['android/core/src/main/kotlin/com/phonedsh/wire',
                             'android/dsh/src/main/kotlin/com/phonedsh/dsh/host/{HostHello,HostChannel,VfsFrames}.kt']},
         'status': [],
         'evidence': ['Tests/PhoneDSHWireTests/GoldenFrameTests.swift',
                      'plugins/channel/src/golden-frames.test.ts',
                      'android/core/src/test/kotlin/com/phonedsh/wire/WireGoldenFramesTest.kt',
                      'shell/crates/pdsh-wire/tests/golden_frames.rs']},
 'P02': {'authority': ['spec/v1/wal.md', 'spec/v1/schema/manifest.schema.json', 'spec/v1/golden/wal'],
         'ends': {'Swift': ['Sources/PhoneDSHLog', 'Sources/PhoneDSHWire/WAL.swift'],
                  'Rust': ['shell/crates/pdsh-wal'],
                  'Kotlin': ['android/core/src/main/kotlin/com/phonedsh/log',
                             'android/dsh/src/main/kotlin/com/phonedsh/dsh/host/{HostWal,WalUplink}.kt'],
                  'TypeScript': ['plugins/channel/src/wal.ts']},
         'status': [],
         'evidence': ['Tests/PhoneDSHWireTests/WALTests.swift',
                      'Tests/PhoneDSHLogTests',
                      'android/core/src/test/kotlin/com/phonedsh/wire/NativeWalGoldenTest.kt',
                      'shell/crates/pdsh-wal/tests/golden_wal.rs']},
 'P03': {'authority': ['spec/v1/exec.md',
                       'spec/v1/handoff.md',
                       'spec/v1/budgets.md',
                       'spec/v1/golden/perturbations'],
         'ends': {'Swift': ['Sources/PhoneDSHController',
                            'Sources/PhoneDSH/Handoff',
                            'Sources/PhoneDSH/Background',
                            'Sources/PhoneDSH/{PhoneDSHLedger,PhoneDSHHost}.swift'],
                  'TypeScript': ['plugins/{exec-bridge,tool-journal,lifecycle-gate,subprocess-xl}/**'],
                  'Kotlin': ['android/controller/src/main',
                             'android/dsh/src/main/kotlin/com/phonedsh/dsh/{exec,journal,background}/**']},
         'status': [],
         'evidence': ['Tests/PhoneDSHControllerTests/{StepMachineJournalContractTests,SideEffectLedgerTests}.swift',
                      'Tests/PhoneDSHTests/PhoneDSHDrainRecoveryContractTests.swift',
                      'plugins/tests/journal-sync.test.ts',
                      'android/**/PerturbationFixtureTest.kt']},
 'P04': {'authority': ['spec/v1/bridge.md',
                       'spec/v1/schema/bridge-message.schema.json',
                       'spec/v1/golden/bridge'],
         'ends': {'Swift': ['Sources/PhoneDSHEngine/WebEngine{NativePreview,DirectoryImport,Scripts}.swift',
                            'examples/probe-app/ProbeKit/MCPControlBridge.swift'],
                  'TypeScript': ['plugins/phone-native-preview/src/protocol.ts'],
                  'Kotlin': ['android/engine/src/main/kotlin/com/phonedsh/engine/{WebViewEngine,NavigationPolicy}.kt']},
         'status': ['target', 'legacy'],
         'evidence': ['spec/v1/tools/bridge_check.py']},
 'P05': {'authority': ['spec/v1/gateway-security.md',
                       'spec/v1/schema/gateway-vector.schema.json',
                       'spec/v1/golden/gateway'],
         'ends': {'Swift': ['Sources/PhoneDSHGateway',
                            'Sources/PhoneDSHLoopback/{HTTPTransport,StreamingForward}.swift'],
                  'TypeScript': ['plugins/llm-bridge', 'plugins/phone-mcp/src/{manager,schema}.ts'],
                  'Kotlin': ['android/net/src/main']},
         'status': [],
         'evidence': ['android/net/src/test/kotlin/com/phonedsh/gateway/GatewayVectorConformanceTest.kt',
                      'Tests/PhoneDSHGatewayTests']},
 'P06': {'authority': ['spec/device/v1/task-delegation.md', 'spec/host/v1/README.md', 'spec/host/v1/event-kinds.md', 'spec/host/v1/golden'],
         'ends': {'Swift': ['Sources/PhoneDSHAgentCore/AgentHarness.swift',
                            'Sources/PhoneDSHAgentCore/DSH',
                            'Sources/PhoneDSH/PhoneDSHEvents.swift'],
                  'Kotlin': ['android/core/src/main/kotlin/com/phonedsh/{agentcore,hostevents}/**',
                             'android/dsh/src/main/kotlin/com/phonedsh/dsh/turn']},
         'status': [],
         'evidence': ['android/core/src/test/kotlin/com/phonedsh/agentcore/HarnessKindClosureTest.kt',
                      'android/core/src/test/kotlin/com/phonedsh/hostevents/HostEventKindSchemaTest.kt',
                      'Tests/PhoneDSHAgentCoreTests']},
 'P07': {'authority': ['spec/device/v1/ble-link.md', 'spec/device/v1/lan-mcp.md', 'spec/device/v1/task-delegation.md', 'spec/host/v1/schema/device-*.schema.json',
                       'docs/design/device-adapter-contract-draft.md'],
         'ends': {'Swift': ['examples/probe-app/ProbeKit/Devices', 'Sources/PhoneDSHBLE', 'Sources/PhoneDSHLAN', 'Sources/PhoneDSHDeviceTasks'],
                  'C': ['firmware/components/pdsh_link_wire', 'firmware/esp32-reference'],
                  'Python': ['examples/lan-mcp-device'],
                  'Kotlin': ['android/domain/src/main/kotlin/com/phonedsh/domain/{device,connector}/**']},
         'status': ['draft', 'target'],
         'evidence': ['android/domain/src/test/kotlin/com/phonedsh/domain/device/DeviceCapabilitiesSchemaTest.kt']},
 'P08': {'authority': ['spec/platform/README.md', 'spec/platform/whitelist.json',
                       'spec/platform/ios-audio-session.md'],
         'ends': {'Swift': ['Sources/PhoneDSH/Background',
                            'examples/probe-app/ProbeKit/PhoneAudioSessionLease.swift',
                            'examples/probe-app/ProbeKit/Capabilities/PhoneMediaTools.swift',
                            'examples/probe-app/PhoneDSHProbe/{BackgroundKeepAlive,ComposerVoiceInput}.swift'],
                  'Kotlin': ['android/{platform,engine,net}/src/main/**']},
         'status': [],
         'evidence': ['spec/platform/tools/platform_check.py',
                      'examples/probe-app/PhoneDSHSimTests/ProbeSceneLifecycleTests.swift',
                      'Tests/PhoneDSHTests/ProbeScenePhaseWiringTests.swift']},
 'P09': {'authority': ['spec/ui/v1/README.md',
                       'spec/ui/v1/tokens.json',
                       'spec/ui/v1/pages',
                       'spec/v1/trajectory.md'],
         'ends': {'Swift': ['examples/probe-app/PhoneDSHProbe'], 'Kotlin': ['android/lib']},
         'status': [],
         'evidence': ['android/**/UiStateProjectorGoldenTest.kt',
                      'android/**/TrajectoryNormalizerTest.kt',
                      'spec/ui/v1/tools/ui_check.py',
                      'spec/ui/v1/tools/page_structure_check.py']},
 'P10': {'authority': ['plugins/workflow-worker/src/protocol.ts'],
         'ends': {'TypeScript': ['plugins/workflow-worker/src']},
         'status': [],
         'evidence': ['plugins/tests/workflow-worker.test.ts']},
 'P11': {'authority': ['plugins/wasi-toolbox/src/vfs-protocol.ts', 'plugins/wasi-toolbox/src/types.ts'],
         'ends': {'TypeScript': ['plugins/wasi-toolbox/src/{vfs-server,vfs-client,sab-client-worker,message-endpoint}.ts']},
         'status': [],
         'evidence': ['plugins/wasi-toolbox/src/{vfs-proxy,vfs-sab}.test.ts']},
 'P12': {'authority': ['shell/include/xzshell.h'],
         'ends': {'Rust': ['shell/crates/{pdsh-ffi,pdsh-jni}/**'],
                  'Swift': ['Sources/PhoneDSHShell'],
                  'Kotlin': ['android/shell/src/main/kotlin/com/phonedsh/shell',
                             'android/core/src/main/kotlin/com/phonedsh/wire/Native*.kt']},
         'status': [],
         'evidence': ['Package.swift', 'android/tools/check-native-alignment.py']},
 'P13': {'authority': ['plugins/phone-shell/src/contract.ts',
                       'plugins/phone-feature-admin/src/contracts.ts',
                       'plugins/phone-mcp/src/protocol.ts',
                       'plugins/phone-directory-import/src/types.ts',
                       'plugins/phone-model-config/src/remote.ts',
                       'plugins/surface-phone/src/management-remote.ts'],
         'ends': {'TypeScript': ['plugins/{phone-shell,phone-feature-admin,phone-mcp,phone-directory-import,phone-model-config}/src/client/**'],
                  'Swift': ['Sources/PhoneDSH/PhoneDSHWorkspaceImportSink.swift']},
         'status': [],
         'evidence': ['plugins/tests/{phone-shell,phone-feature-admin,phone-mcp,phone-directory-import}.test.ts']},
 'P14': {'authority': ['Sources/PhoneDSH/ChannelDSHTransport.swift'],
         'ends': {'TypeScript': ['plugins/worker-entry/src/mux-{bridge,tunnel,json}.ts'],
                  'Swift': ['Sources/PhoneDSHAgentCore/DSH/DSHRemoteTransport.swift'],
                  'Kotlin': ['android/dsh/src/main/kotlin/com/phonedsh/dsh/turn/DshTurnClient.kt']},
         'status': [],
         'evidence': []},
 'P15': {'authority': ['Sources/PhoneDSH/{PhoneDSHWorkerCommand,PhoneDSHRecovery,PhoneDSHDescendantDrain}.swift'],
         'ends': {'JavaScript': ['plugins/surface-phone/src/*-controller.js']},
         'status': [],
         'evidence': ['Tests/PhoneDSHTests/PhoneDSHWorkerCommandTests.swift',
                      'plugins/tests/worker-command-controller.test.ts']},
 'P16': {'authority': ['Sources/PhoneDSH/PhoneDSH.swift',
                       'Sources/PhoneDSHEngine/WebEngineConfiguration.swift'],
         'ends': {'Kotlin': ['android/engine/src/main/kotlin/com/phonedsh/engine/WorkerEnvironment.kt'],
                  'JavaScript': ['plugins/worker-entry/www/boot.js'],
                  'TypeScript': ['plugins/worker-entry/src/{web-boot,entry}.ts']},
         'status': [],
         'evidence': []},
 'P17': {'authority': ['plugins/exec-bridge/src/client.ts'],
         'ends': {'Swift': ['Sources/PhoneDSHLoopback/LoopbackServer.swift',
                            'Sources/PhoneDSHAgentCore/ExecBridgeHosting.swift',
                            'Sources/PhoneDSHGateway/ModelGateway.swift']},
         'status': [],
         'evidence': []},
 'P18': {'authority': ['plugins/worker-entry/src/capabilities.ts',
                       'plugins/phone-mcp/src/schema.ts',
                       'plugins/phone-model-config/src/model-config.ts'],
         'ends': {'Swift': ['Sources/PhoneDSHLog/MaterializedInvariant.swift',
                            'Sources/PhoneDSHScenario/ScenarioBudgets.swift',
                            'Sources/PhoneDSH/Phone*Settings.swift']},
         'status': [],
         'evidence': []},
 'P19': {'authority': ['examples/probe-app/ProbeKit/Capabilities/PhoneToolEnvelope.swift',
                       'shell/crates/pdsh-phone/src/lib.rs'],
         'ends': {'Rust': ['shell/crates/pdsh-phone/src/lib.rs'],
                  'Kotlin': ['android/dsh/src/main/kotlin/com/phonedsh/dsh/host/PhoneInfoTool.kt']},
         'status': [],
         'evidence': []},
 'P20': {'authority': ['plugins/scripts/pack-image.mjs', 'plugins/dsh-pin.json'],
         'ends': {'Swift': ['Sources/PhoneDSHLoopback/LoopbackServer.swift'],
                  'Kotlin': ['android/engine/src/main/kotlin/com/phonedsh/engine/*WorkerAssetSource.kt']},
         'status': [],
         'evidence': []},
 'P21': {'authority': ['spec/v1/render-media-v1.md', 'spec/v1/office-ir-v1.json'],
         'ends': {'Swift': ['Sources/PhoneDSHEngine/{PageSchemeHandler,PageSurface}.swift',
                            'examples/probe-app/ProbeKit/Office/OfficeIR.swift']},
         'status': ['draft'],
         'evidence': []},
 'P24': {'authority': ['spec/toolchain/v1/apple-package-lock.md', 'spec/toolchain/v1/schema/apple-package-lock-case.schema.json', 'spec/toolchain/v1/golden/apple-package-lock-cases.jsonl'],
         'ends': {'SwiftPM': ['Package.resolved'], 'Xcode': ['examples/probe-app/project.yml', 'scripts/ci/xcode-resolve.sh']},
         'status': ['partial'],
         'evidence': ['scripts/ci/xcode-resolve.sh']},
 'P23': {'authority': ['spec/toolchain/v1/sdk-manager.md', 'spec/toolchain/v1/schema/sdk-manager-listing.schema.json', 'spec/toolchain/v1/golden/sdk-manager-listing.jsonl'],
         'ends': {'Shell': ['android/tools/bootstrap-android-toolchain.sh'], 'Python': ['android/tools/test_gradle_build_inputs.py']},
         'status': ['partial'],
         'evidence': ['android/tools/test_bootstrap_android_toolchain.py']},
 'P22': {'authority': ['spec/v1/schema/{scenario-*,perturbation,upstream-script}.schema.json'],
         'ends': {'Swift': ['Sources/PhoneDSH{Scenario,Harness}/**'],
                  'Kotlin': ['android/testkit'],
                  'Python': ['scripts/ci/scenarios']},
         'status': [],
         'evidence': []},
 'P25': {'authority': ['spec/bot/v1/event-envelope.schema.json',
                       'spec/bot/v1/golden/event-envelope.json'],
         'ends': {'Swift': ['Sources/PhoneDSHBot']},
         'status': ['target'],
         'evidence': ['spec/bot/v1/tools/validate_vectors.py', 'Tests/PhoneDSHBotTests']},
 'P26': {'authority': ['spec/bot/v1', 'spec/bot/v2'],
         'ends': {'Swift': ['Sources/PhoneDSHBot']},
         'status': ['target'],
         'evidence': ['spec/bot/v1/tools/validate_vectors.py',
                      'spec/bot/v2/tools/validate_vectors.py']},
 'P27': {'authority': ['spec/bot/v1'],
         'ends': {'Swift': ['Sources/PhoneDSHBot',
                            'examples/probe-app/PhoneDSHProbe']},
         'status': ['target'],
         'evidence': ['spec/bot/v1/tools/validate_vectors.py']},
 # P28 is a frozen target with no implementation tree yet.  Its structured
 # ends are the shared contract-side checker/fixtures; the planned relay,
 # plugin and Swift paths are recorded in spec/README.md §3.1 and the change
 # record.  The contract owner adds those globs when the directories land.
 'P28': {'authority': ['spec/pclink/v1/README.md', 'spec/pclink/v1/schema',
                       'spec/pclink/v1/golden', 'spec/pclink/v1/endpoints.json'],
         'ends': {'Node': ['spec/pclink/v1/tools/vectors.mjs'],
                  'Swift': ['spec/pclink/v1/golden']},
         'status': ['target'],
         'evidence': ['spec/pclink/v1/tools/vectors.mjs',
                      'spec/pclink/v1/tools/check_samples.py']}}


# New HarmonyOS ends remain partial until their runtime matrix is verified.
HARMONY_ENDS = {'P01': ['harmony/host-rust/src/ws.rs', 'harmony/host-rust/src/host.rs'],
 'P02': ['harmony/host-rust/src/wal.rs', 'harmony/host-rust/src/overlay.rs'],
 'P03': ['harmony/host-rust/src/ws.rs', 'harmony/host-rust/src/wal.rs'],
 'P04': ['harmony/entry/src/main/ets/host/HostBridge.ets',
         'harmony/web/engine.mjs',
         'harmony/web/product-worker.mjs'],
 'P05': ['harmony/entry/src/main/ets/host/HostHttpProxy.ets',
         'harmony/entry/src/main/ets/host/HostModelAlias.ets',
         'harmony/host-rust/src/http.rs'],
 'P06': ['harmony/entry/src/main/ets/host/TranscriptProjection.ets',
         'harmony/entry/src/main/ets/host/HostService.ets'],
 'P08': ['harmony/entry/src/main/ets/entryability/EntryAbility.ets'],
 'P09': ['harmony/entry/src/main/ets/ui', 'harmony/entry/src/main/ets/model/Contracts.ets'],
 'P12': ['harmony/host-rust/include/pdsh_host.h',
         'harmony/entry/src/main/cpp/napi_init.cpp',
         'harmony/entry/src/main/cpp/types/libpdshhost/index.d.ts'],
 'P13': ['harmony/entry/src/main/ets/host/HostService.ets'],
 'P14': ['harmony/web/engine.mjs'],
 'P16': ['harmony/host-rust/src/host.rs', 'harmony/web/product-worker.mjs'],
 'P18': ['harmony/entry/src/main/ets/host/HostPersistence.ets',
         'harmony/entry/src/main/ets/model/ProviderProfiles.ets'],
 'P20': ['harmony/tools/stage-runtime.mjs', 'harmony/host-rust/src/bundle.rs']}
for _contract, _paths in HARMONY_ENDS.items():
    PATH_PROJECTIONS[_contract]['ends']['HarmonyOS'] = _paths
    if 'partial' not in PATH_PROJECTIONS[_contract]['status']:
        PATH_PROJECTIONS[_contract]['status'].append('partial')
PATH_PROJECTIONS['P12']['authority'].extend(['harmony/host-rust/include/pdsh_host.h', 'spec/platform/android-module-map.json'])
PATH_PROJECTIONS['P08']['authority'].append('spec/platform/android-module-map.json')
PATH_PROJECTIONS['P09']['authority'].append('spec/ui/v1/page-completeness.md')
PATH_PROJECTIONS['P09']['authority'].append('spec/ui/v1/interaction.md')
PATH_PROJECTIONS['P09']['evidence'].extend(['spec/ui/v1/tools/extract_ios_pages.py', 'spec/ui/v1/tools/test_extract_ios_pages.py'])
PATH_PROJECTIONS['P12']['ends']['Python'] = ['android/tools/structure_check.py']
PATH_PROJECTIONS['P08']['evidence'].extend(['android/tools/structure_check.py', 'android/tools/test_structure_check.py'])
PATH_PROJECTIONS['P12']['evidence'].extend(['android/tools/structure_check.py', 'android/tools/test_structure_check.py'])
PATH_PROJECTIONS['P18']['authority'].append('harmony/entry/src/main/ets/host/HostPersistence.ets')
PATH_PROJECTIONS['P18']['authority'].append('spec/device/v1/legacy-identity-preferences.md')
# tono-account user credential (PC-20261108-tono-account-login): one clause, two contracts.
PATH_PROJECTIONS['P05']['authority'].extend(['spec/v1/tono-account.md', 'spec/v1/golden/tono-account'])
PATH_PROJECTIONS['P05']['ends']['Swift'].append('Sources/PhoneDSH/TonoAccount')
PATH_PROJECTIONS['P05']['evidence'].extend(['Tests/PhoneDSHGatewayTests/TonoCloudResponsePolicyTests.swift',
                                            'android/net/src/test/kotlin/com/phonedsh/account/TonoAccountCasesTest.kt'])
PATH_PROJECTIONS['P18']['authority'].append('spec/v1/tono-account.md')
PATH_PROJECTIONS['P18']['ends']['Swift'].append('Sources/PhoneDSH/TonoAccount')
PATH_PROJECTIONS['P18']['ends']['Kotlin'] = ['android/net/src/main/kotlin/com/phonedsh/account']
PATH_PROJECTIONS['P18']['evidence'].extend(['Tests/PhoneDSHTests/TonoAccountSessionTests.swift',
                                            'android/net/src/test/kotlin/com/phonedsh/account/TonoAccountSessionTest.kt'])
PATH_PROJECTIONS['P18']['ends']['Swift'].append('Sources/PhoneDSHBLE/BLEIdentity.swift')
PATH_PROJECTIONS['P18']['evidence'].append('Tests/PhoneDSHBLETests/BLEIdentityTests.swift')
PATH_PROJECTIONS['P07']['authority'].append('spec/device/v1/ble-secure-session.md')
PATH_PROJECTIONS['P07']['evidence'].append('spec/v1/tools/test_ble_secure_session_golden.py')


def registry_schema():
    string = {'type': 'string', 'minLength': 1}
    paths = {'type': 'array', 'items': string, 'minItems': 1, 'uniqueItems': True}
    trigger = {'type': 'object', 'required': ['glob'], 'additionalProperties': False,
               'properties': {'glob': string, 'exclude': paths, 'contains_any': paths}}
    source = {'type': 'object', 'required': ['authority', 'ends', 'evidence', 'triggers'],
              'additionalProperties': False,
              'properties': {key: string for key in ('authority', 'ends', 'evidence', 'triggers')}}
    contract = {
        'type': 'object',
        'required': ['id', 'owner_role', 'authority', 'ends', 'triggers', 'status', 'evidence', 'source'],
        'additionalProperties': False,
        'properties': {
            'id': {'type': 'string', 'pattern': 'P[0-9]{2}'},
            'owner_role': string,
            'authority': paths,
            'ends': {'type': 'object', 'additionalProperties': paths},
            'triggers': {'type': 'array', 'items': trigger, 'minItems': 1},
            'status': {'type': 'array', 'items': {'type': 'string', 'enum': [
                'implemented', 'partial', 'target', 'draft', 'legacy', 'deprecated']},
                'uniqueItems': True},
            'evidence': {'type': 'array', 'items': string, 'uniqueItems': True},
            'source': source,
        },
    }
    return {'type': 'array', 'minItems': 1, 'items': contract}


def build_registry(root):
    text = (Path(root) / 'spec/README.md').read_text(encoding='utf-8')
    tables = baseline_tables(text)
    if set(tables[3]) != set(tables[4]) or set(tables[3]) != set(PATH_PROJECTIONS):
        raise SpecError('baseline sections 3/4 and reviewed path projections must have the same IDs')
    records = []
    for ident, cells in tables[3].items():
        projection = copy.deepcopy(PATH_PROJECTIONS[ident])
        raw_triggers = tables[4][ident][1]
        records.append({
            'id': ident,
            'owner_role': cells[0][4:],
            'authority': projection['authority'],
            'ends': projection['ends'],
            'triggers': baseline_triggers(raw_triggers, ident),
            'status': projection['status'],
            'evidence': projection['evidence'],
            'source': {'authority': cells[1], 'ends': cells[2], 'evidence': cells[3],
                       'triggers': raw_triggers},
        })
    schema = registry_schema()
    validate_json(records, schema, 'generated registry')
    data = {'format_version': 1, 'schema': schema, 'contracts': records}
    # Fixed UTF-8 encoding, key order, indentation and final newline are part of
    # the reproducible artifact, rather than semantic-only JSON equality.
    return (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.', help='repository root')
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--write', action='store_true', help='regenerate the derived registry')
    modes.add_argument('--check', action='store_true', help='fail on any byte difference; never write')
    args = parser.parse_args(argv)
    try:
        root = Path(args.root).resolve()
        generated = build_registry(root)
        target = root / 'spec/registry.json'
        if args.write:
            target.write_bytes(generated)
            print('PASS registry build: wrote spec/registry.json')
        else:
            if target.read_bytes() != generated:
                raise SpecError('spec/registry.json differs byte-for-byte; run registry_build.py --write')
            print('PASS registry build: spec/registry.json is byte-identical to regenerated output')
        return 0
    except (SpecError, OSError, ValueError, KeyError, TypeError) as exc:
        print('FAIL registry build: ' + str(exc))
        return 1


if __name__ == '__main__':
    sys.exit(main())
