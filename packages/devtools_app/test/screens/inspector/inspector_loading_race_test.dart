// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

// Fake construction requires unawaited futures.
// ignore_for_file: discarded_futures

/// Tests that pin down a race in the Inspector's first-load flow.
///
/// Scenario: when DevTools attaches to a Flutter app that is already idle (no
/// new frames being painted), `WidgetInspectorService.isWidgetTreeReady` may
/// return `false` on the first probe. The controller's only retry path is the
/// `Flutter.Frame` extension event, which is **never** dispatched while the
/// app is idle. The result is a `CenteredCircularProgressIndicator` that
/// never resolves until the user hot-restarts the app, which causes startup
/// frames to fire and unblocks the inspector.
///
/// `FakeVmServiceWrapper.onExtensionEvent` returns `Stream.empty()`, so this
/// test environment naturally reproduces the "no frames ever arrive" state
/// without any extra setup.
library;

import 'package:devtools_app/devtools_app.dart';
import 'package:devtools_app_shared/ui.dart';
import 'package:devtools_app_shared/utils.dart';
import 'package:devtools_test/devtools_test.dart';
import 'package:devtools_test/helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide Fake;
import 'package:mockito/mockito.dart';

import '../../test_infra/flutter_test_storage.dart';

/// A [FakeInspectorService] whose `isWidgetTreeReady()` answer is
/// programmable per call. Used to simulate the race where the Flutter app
/// becomes ready a few moments after the inspector starts probing.
class _ProgrammableFakeInspectorService extends FakeInspectorService {
  /// Each entry is the answer for the corresponding call to
  /// [isWidgetTreeReady]. Once exhausted, [tailAnswer] is returned forever.
  final List<bool> answers = [];
  bool tailAnswer = false;
  int callCount = 0;

  @override
  Future<bool> isWidgetTreeReady() async {
    final i = callCount++;
    if (i < answers.length) return answers[i];
    return tailAnswer;
  }
}

/// A [FakeServiceConnectionManager] variant whose [inspectorService] is a
/// programmable fake.
class _RaceFakeServiceConnectionManager extends FakeServiceConnectionManager {
  _RaceFakeServiceConnectionManager(this._inspectorService);

  final _ProgrammableFakeInspectorService _inspectorService;

  @override
  // ignore: overridden_fields, deliberate test-only override of a Fake field.
  // ignore: invalid_override
  InspectorService get inspectorService => _inspectorService;
}

void main() {
  final screen = InspectorScreen();

  late _ProgrammableFakeInspectorService programmableInspectorService;
  late _RaceFakeServiceConnectionManager fakeServiceConnection;
  const windowSize = Size(2600.0, 1200.0);

  final debuggerController = createMockDebuggerControllerWithDefaults();

  Widget buildInspectorScreen() {
    return wrapWithControllers(
      Builder(builder: screen.build),
      debugger: debuggerController,
      inspector: InspectorScreenController(),
    );
  }

  setUp(() {
    programmableInspectorService = _ProgrammableFakeInspectorService();
    fakeServiceConnection = _RaceFakeServiceConnectionManager(
      programmableInspectorService,
    );
    mockConnectedApp(fakeServiceConnection.serviceManager.connectedApp!);
    when(
      fakeServiceConnection.errorBadgeManager.errorCountNotifier('inspector'),
    ).thenReturn(ValueNotifier<int>(0));

    setGlobal(
      DevToolsEnvironmentParameters,
      ExternalDevToolsEnvironmentParameters(),
    );
    setGlobal(ServiceConnectionManager, fakeServiceConnection);
    setGlobal(IdeTheme, IdeTheme());
    setGlobal(PreferencesController, PreferencesController());
    setGlobal(Storage, FlutterTestStorage());
    setGlobal(NotificationService, NotificationService());
    fakeServiceConnection.consoleService.ensureServiceInitialized();
  });

  InspectorController controllerFor(WidgetTester tester) {
    final bodyState =
        tester.state(find.byType(InspectorScreenBody))
            as InspectorScreenBodyState;
    return bodyState.controller;
  }

  // Drives the test clock long enough for InspectorController.init() to run
  // through onServiceAvailable, _handleConnectionStart, setActivate(true),
  // maybeLoadUI(), and the awaited isWidgetTreeReady() probe — all without
  // calling pumpAndSettle (which never settles because periodic listeners
  // keep scheduling frames in this environment).
  Future<void> driveControllerInit(WidgetTester tester) async {
    // 30 x 50ms = 1.5s. Long enough for init() to resolve onServiceAvailable
    // and allocate _treeGroups / _selectionGroups in this test environment.
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // Drives wall-clock time forward to let bounded retries fire.
  Future<void> driveRetries(WidgetTester tester, Duration duration) async {
    const stepMs = 50;
    final steps = duration.inMilliseconds ~/ stepMs;
    for (int i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: stepMs));
    }
  }

  // Unmounts the inspector and pumps any remaining retry timers so the
  // test framework's "no pending timers" assertion at teardown is satisfied.
  Future<void> teardownInspector(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Drain anything queued by the controller's dispose.
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgetsWithWindowSize(
    'spinner is shown initially while waiting for the widget tree',
    windowSize,
    (tester) async {
      await tester.pumpWidget(buildInspectorScreen());
      // One pump only — controller is still wiring up.
      await tester.pump();
      expect(find.byType(CenteredCircularProgressIndicator), findsWidgets);
      expect(controllerFor(tester).flutterAppFrameReady, isFalse);

      await teardownInspector(tester);
    },
  );

  testWidgetsWithWindowSize(
    'BUG: spinner stays stuck when isWidgetTreeReady=false and no '
    'Flutter.Frame event ever arrives',
    windowSize,
    (tester) async {
      // Permanently unready — and no Flutter.Frame events because
      // FakeVmServiceWrapper.onExtensionEvent is Stream.empty().
      programmableInspectorService.tailAnswer = false;

      await tester.pumpWidget(buildInspectorScreen());
      await driveControllerInit(tester);
      await driveRetries(tester, const Duration(seconds: 3));

      final controller = controllerFor(tester);
      expect(
        controller.flutterAppFrameReady,
        isFalse,
        reason: 'No Flutter.Frame event ever fires; tree never becomes ready.',
      );
      expect(
        find.byType(CenteredCircularProgressIndicator),
        findsWidgets,
        reason:
            'Inspector tree shows a spinner because rows.length stays at 0. '
            'This is the user-visible "keeps loading" symptom.',
      );

      await teardownInspector(tester);
    },
  );

  testWidgetsWithWindowSize(
    'spinner clears once a Flutter.Frame arrives (simulates hot-restart)',
    windowSize,
    (tester) async {
      // Permanently false from isWidgetTreeReady — only the frame event can
      // unstick the controller in this scenario.
      programmableInspectorService.tailAnswer = false;

      await tester.pumpWidget(buildInspectorScreen());
      await driveControllerInit(tester);

      final controller = controllerFor(tester);

      // Sanity: we are stuck before the frame event.
      expect(controller.flutterAppFrameReady, isFalse);

      // Simulate a Flutter.Frame extension event being delivered to the
      // service's clients. This is what InspectorService does in
      // onExtensionVmServiceReceived when kind == FlutterEvent.frame.
      controller.onFlutterFrame();
      await tester.pump();

      expect(
        controller.flutterAppFrameReady,
        isTrue,
        reason: 'onFlutterFrame() flips frameReady to true.',
      );

      await teardownInspector(tester);
    },
  );

  testWidgetsWithWindowSize(
    'BUG: post-hot-restart, frames arrive but tree never re-loads',
    windowSize,
    (tester) async {
      // Reproduces the real-world scenario captured in production logs:
      //
      //  1. Inspector loads successfully (initial connect).
      //  2. App is hot-restarted while the Chrome tab is backgrounded.
      //  3. The new isolate fires before runApp() completes; the eval
      //     `WidgetInspectorService.instance.isWidgetTreeReady()` throws
      //     "Binding has not yet been initialized" on the device. The
      //     EvalOnDartLibrary catches it and `isWidgetTreeReady()` resolves
      //     to `false`.
      //  4. The mainIsolate listener calls `setActivate(false)` then
      //     `setActivate(true)`. The reactivation calls `maybeLoadUI()`
      //     which probes readiness, gets `false`, and gives up.
      //  5. Eventually frames arrive (e.g. when the tab comes back to
      //     foreground). The very first frame triggers `maybeLoadUI()`
      //     again, which now takes the `frameReady=true` branch and
      //     calls `updateSelectionFromService`. But that path swallows
      //     errors silently, and on a fake/incomplete service it does
      //     NOT trigger `_recomputeTreeRoot()`, so the tree stays empty.
      //  6. Subsequent frames are gated by `treeLoadStarted=true` and
      //     no longer call `maybeLoadUI()`. The spinner never clears.
      //
      // This test should FAIL until the controller is fixed.

      // Phase 1 — initial successful load.
      programmableInspectorService.tailAnswer = true;
      await tester.pumpWidget(buildInspectorScreen());
      await driveControllerInit(tester);
      final controller = controllerFor(tester);
      expect(
        controller.flutterAppFrameReady,
        isTrue,
        reason: 'Phase 1 sanity: initial load should succeed.',
      );

      // Phase 2 — simulate hot-restart with a backgrounded tab. Set the
      // fake to return `false` for the next isolate's first probe (mimics
      // the binding-not-initialized eval failure), then trigger an isolate
      // restart by calling `onIsolateStopped` directly. After the restart,
      // we will NOT deliver any frames (tab backgrounded), then later
      // simulate the tab coming forward by delivering frames.
      programmableInspectorService.callCount = 0;
      programmableInspectorService.answers.clear();
      programmableInspectorService.tailAnswer = false;
      controller.onIsolateStopped();
      // Reactivate as the mainIsolate listener would after the new isolate.
      controller.setActivate(true);
      await driveRetries(tester, const Duration(milliseconds: 500));

      expect(
        controller.flutterAppFrameReady,
        isFalse,
        reason: 'Probe returned false -> stuck.',
      );

      // Phase 3 — tab comes back to foreground; frames flood in. We expect
      // the controller to recover and re-load the tree.
      for (int i = 0; i < 10; i++) {
        controller.onFlutterFrame();
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        controller.flutterAppFrameReady,
        isTrue,
        reason:
            'onFlutterFrame() must mark frameReady=true so the next probe '
            'or load attempt can succeed.',
      );
      // The root failure mode in production: spinner is still showing
      // because the tree never repopulated.
      expect(
        find.byType(CenteredCircularProgressIndicator),
        findsNothing,
        reason:
            'After frames arrive post-hot-restart, the inspector should '
            'recover and render the tree. Today it stays on the spinner — '
            'this is the user-visible bug.',
      );

      await teardownInspector(tester);
    },
  );
}
