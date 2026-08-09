import AppKit
import MillerLiveAudio
import MillerWake
import WebKit

enum WebKitLivePeerMediaRequest: Equatable, Sendable {
    case microphone
    case camera
    case cameraAndMicrophone
    case other
}

enum WebKitLivePeerPermissionDecision: Equatable, Sendable {
    case grant
    case deny
}

enum WebKitLivePeerNavigationDecision: Equatable, Sendable {
    case allowInitialDocument
    case deny
}

enum WebKitLivePeerScriptOperation: Hashable, Sendable {
    case prepareOffer
    case applyAnswer
    case setMuted(Bool)
    case connectionState
    case close
}

@MainActor
final class WebKitLivePeerPageReadiness {
    private enum Status {
        case loading
        case ready
        case failed
    }

    private let timeout: Duration
    private var status: Status = .loading
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledWaiters: Set<UUID> = []

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    var waiterCount: Int { waiters.count }

    func waitUntilReady() async throws {
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await self.waitForSignal()
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw LiveAudioPeerError.connectionFailed
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw LiveAudioPeerError.connectionFailed
            }
        }
    }

    func finish() {
        guard status == .loading else { return }
        status = .ready
        resumeWaiters()
    }

    func fail() {
        guard status == .loading else { return }
        status = .failed
        resumeWaiters()
    }

    private func waitForSignal() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelledWaiters.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                switch status {
                case .ready:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: LiveAudioPeerError.connectionFailed)
                case .loading:
                    waiters[id] = continuation
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelWaiter(id) }
        })
    }

    private func cancelWaiter(_ id: UUID) {
        guard status == .loading else { return }
        cancelledWaiters.insert(id)
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            switch status {
            case .ready:
                continuation.resume()
            case .failed, .loading:
                continuation.resume(throwing: LiveAudioPeerError.connectionFailed)
            }
        }
    }
}

@MainActor
protocol WebKitLivePeerScriptEvaluating: AnyObject, Sendable {
    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String
}

@MainActor
protocol WebKitLivePeerPreparedAudioEvaluating: AnyObject, Sendable {
    func injectPreparedAudio(_ audio: WakeWordPreparedCommandAudio) async throws
}

@MainActor
protocol PreparedCommandAudioLivePeer: AnyObject {
    func preparePreparedCommandAudio(
        _ audio: WakeWordPreparedCommandAudio
    ) async throws
}

@MainActor
final class WebKitLivePeer: LiveAudioPeer, LiveAudioPeerConnectionMonitoring,
    PreparedCommandAudioLivePeer {
    static let baseOrigin = URL(string: "https://miller.invalid/")!
    static let maximumSDPBytes = 65_536
    private static let maximumResultBytes = 65_536

    enum State {
        case idle
        case preparingOffer
        case offerPrepared
        case applyingAnswer
        case connected
        case closed
    }

    let peerView: NSView?
    private let evaluator: any WebKitLivePeerScriptEvaluating
    private let operationTimeout: Duration
    private var state: State = .idle
    private var pendingPreparedAudio: WakeWordPreparedCommandAudio?
    private var preparedAudioInjected = false

    init(
        evaluator: any WebKitLivePeerScriptEvaluating,
        peerView: NSView? = nil,
        operationTimeout: Duration = .seconds(10)
    ) {
        self.evaluator = evaluator
        self.peerView = peerView
        self.operationTimeout = operationTimeout
    }

    convenience init(nativeMicrophoneAuthorized: @escaping @MainActor @Sendable () -> Bool) {
        let evaluator = SystemWebKitLivePeerEvaluator(
            nativeMicrophoneAuthorized: nativeMicrophoneAuthorized
        )
        self.init(evaluator: evaluator, peerView: evaluator.view)
    }

    func prepareOffer() async throws -> String {
        guard state == .idle else { throw LiveAudioPeerError.invalidState }
        state = .preparingOffer
        do {
            let offer = try await call(.prepareOffer)
            guard state == .preparingOffer, Self.isValidSDP(offer) else {
                throw LiveAudioPeerError.invalidOffer
            }
            state = .offerPrepared
            return offer
        } catch is CancellationError {
            await close()
            throw CancellationError()
        } catch let error as LiveAudioPeerError {
            await close()
            throw error
        } catch {
            await close()
            throw LiveAudioPeerError.connectionFailed
        }
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        guard state == .offerPrepared else { throw LiveAudioPeerError.invalidState }
        guard Self.isValidSDP(answer) else { throw LiveAudioPeerError.invalidAnswer }
        state = .applyingAnswer
        do {
            let result = try await call(.applyAnswer, answer: answer)
            guard state == .applyingAnswer, result == "connected" else {
                throw LiveAudioPeerError.connectionFailed
            }
            state = .connected
            try await injectPreparedAudioIfNeeded()
        } catch is CancellationError {
            await close()
            throw CancellationError()
        } catch let error as LiveAudioPeerError {
            await close()
            throw error
        } catch {
            await close()
            throw LiveAudioPeerError.connectionFailed
        }
    }

    func setMuted(_ muted: Bool) async throws {
        guard state == .connected else { throw LiveAudioPeerError.invalidState }
        do {
            guard try await call(.setMuted(muted)) == "ok" else {
                await close()
                throw LiveAudioPeerError.connectionFailed
            }
        } catch is CancellationError {
            await close()
            throw CancellationError()
        } catch let error as LiveAudioPeerError {
            await close()
            throw error
        } catch {
            await close()
            throw LiveAudioPeerError.connectionFailed
        }
    }

    func waitForConnectionFailure() async throws {
        guard state == .connected else { throw LiveAudioPeerError.invalidState }
        do {
            while true {
                try Task.checkCancellation()
                guard try await call(.connectionState) == "connected" else {
                    throw LiveAudioPeerError.connectionFailed
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LiveAudioPeerError {
            throw error
        } catch {
            throw LiveAudioPeerError.connectionFailed
        }
    }

    func close() async {
        guard state != .closed else { return }
        state = .closed
        pendingPreparedAudio = nil
        _ = try? await call(.close)
    }

    func preparePreparedCommandAudio(
        _ audio: WakeWordPreparedCommandAudio
    ) async throws {
        guard state != .closed,
              !preparedAudioInjected,
              pendingPreparedAudio == nil,
              audio.sampleRate == 16_000,
              !audio.samples.isEmpty,
              audio.samples.count <= 32_000
        else { throw LiveAudioPeerError.invalidState }
        pendingPreparedAudio = audio
        if state == .connected {
            try await injectPreparedAudioIfNeeded()
        }
    }

    private func injectPreparedAudioIfNeeded() async throws {
        guard let audio = pendingPreparedAudio else { return }
        guard let evaluator = evaluator as? any WebKitLivePeerPreparedAudioEvaluating else {
            throw LiveAudioPeerError.unavailable
        }
        do {
            try await evaluator.injectPreparedAudio(audio)
            preparedAudioInjected = true
            pendingPreparedAudio = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LiveAudioPeerError {
            throw error
        } catch {
            throw LiveAudioPeerError.connectionFailed
        }
    }

    static func mediaPermissionDecision(
        nativeMicrophoneAuthorized: Bool,
        originScheme: String,
        originHost: String,
        isMainFrame: Bool,
        request: WebKitLivePeerMediaRequest
    ) -> WebKitLivePeerPermissionDecision {
        guard nativeMicrophoneAuthorized,
              originScheme == "https",
              originHost == baseOrigin.host,
              isMainFrame,
              request == .microphone
        else { return .deny }
        return .grant
    }

    static func navigationDecision(
        url: URL?,
        isMainFrame: Bool,
        didFinishInitialLoad: Bool
    ) -> WebKitLivePeerNavigationDecision {
        guard !didFinishInitialLoad,
              isMainFrame,
              url?.scheme == baseOrigin.scheme,
              url?.host == baseOrigin.host,
              url?.path == "/"
        else { return .deny }
        return .allowInitialDocument
    }

    private func call(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String? = nil
    ) async throws -> String {
        let race = WebKitLivePeerCallRace<String>()
        let timeout = operationTimeout
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                Task { @MainActor [evaluator] in
                    do {
                        race.resolve(.success(
                            try await evaluator.evaluate(operation, answer: answer)
                        ))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    race.resolve(.failure(LiveAudioPeerError.connectionFailed))
                }
            }
        }, onCancel: {
            race.resolve(.failure(CancellationError()))
        })
        guard result.utf8.count <= Self.maximumResultBytes else {
            throw LiveAudioPeerError.connectionFailed
        }
        return result
    }

    private static func isValidSDP(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumSDPBytes
            && !value.utf8.contains(0)
            && value.split(whereSeparator: \.isNewline).first == "v=0"
    }

    static let localHTML = """
    <!doctype html>
    <meta charset="utf-8">
    <script>
    (() => {
      let pc = null;
      let localStream = null;
      let outboundStream = null;
      let audioContext = null;
      let microphoneSource = null;
      let destination = null;
      let remoteStream = null;
      let channel = null;
      let audio = null;
      let closed = false;
      let preparedAudioInjected = false;
      const connected = () => pc && pc.connectionState === "connected";
      const waitForConnected = () => new Promise((resolve, reject) => {
        if (connected()) { resolve(); return; }
        const timeout = setTimeout(() => reject(new Error("connection failed")), 10000);
        pc.addEventListener("connectionstatechange", () => {
          if (connected()) { clearTimeout(timeout); resolve(); }
          if (pc.connectionState === "failed" || pc.connectionState === "closed") {
            clearTimeout(timeout); reject(new Error("connection failed"));
          }
        }, { once: false });
      });
      window.millerLive = Object.freeze({
        async prepareOffer() {
          if (pc || closed) throw new Error("invalid state");
        pc = new RTCPeerConnection();
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
        audioContext = new AudioContext({ sampleRate: 16000 });
        await audioContext.resume();
        microphoneSource = audioContext.createMediaStreamSource(localStream);
        destination = audioContext.createMediaStreamDestination();
        microphoneSource.connect(destination);
        outboundStream = destination.stream;
        for (const track of outboundStream.getAudioTracks()) pc.addTrack(track, outboundStream);
          remoteStream = new MediaStream();
          audio = document.createElement("audio");
          audio.autoplay = true;
          audio.playsInline = true;
          audio.srcObject = remoteStream;
          pc.ontrack = event => {
            if (event.track.kind === "audio") remoteStream.addTrack(event.track);
          };
          channel = pc.createDataChannel("oai-events");
          const offer = await pc.createOffer();
          await pc.setLocalDescription(offer);
          if (!pc.localDescription || !pc.localDescription.sdp) throw new Error("missing offer");
          return pc.localDescription.sdp;
        },
        async applyAnswer(answer) {
          if (!pc || closed || pc.remoteDescription) throw new Error("invalid state");
          await pc.setRemoteDescription({ type: "answer", sdp: answer });
          await waitForConnected();
          return "connected";
        },
        async setMuted(muted) {
          if (!outboundStream || closed) throw new Error("invalid state");
          for (const track of outboundStream.getAudioTracks()) track.enabled = !muted;
          return "ok";
        },
        async injectPreparedCommandAudio(pcmBase64, sampleRate) {
          if (!audioContext || !destination || closed || preparedAudioInjected || sampleRate !== 16000) {
            throw new Error("invalid state");
          }
          const encoded = atob(pcmBase64);
          if (!encoded.length || encoded.length > 64000 || encoded.length % 2 !== 0) {
            throw new Error("invalid audio");
          }
          const buffer = audioContext.createBuffer(1, encoded.length / 2, sampleRate);
          const samples = buffer.getChannelData(0);
          for (let index = 0; index < samples.length; index++) {
            const low = encoded.charCodeAt(index * 2);
            const high = encoded.charCodeAt(index * 2 + 1);
            let value = (high << 8) | low;
            if (value & 0x8000) value -= 0x10000;
            samples[index] = value / 32768;
          }
          const source = audioContext.createBufferSource();
          source.buffer = buffer;
          source.connect(destination);
          await audioContext.resume();
          source.start();
          preparedAudioInjected = true;
          return "ok";
        },
        connectionState() {
          if (!pc || closed) throw new Error("invalid state");
          return pc.connectionState;
        },
        async close() {
          if (closed) return "ok";
          closed = true;
          if (localStream) for (const track of localStream.getTracks()) track.stop();
          if (outboundStream) for (const track of outboundStream.getTracks()) track.stop();
          if (microphoneSource) microphoneSource.disconnect();
          if (audioContext) { try { await audioContext.close(); } catch (_) {} }
          if (remoteStream) for (const track of remoteStream.getTracks()) track.stop();
          if (audio) { audio.pause(); audio.srcObject = null; audio.removeAttribute("src"); audio.load(); }
          if (channel) channel.close();
          if (pc) pc.close();
          return "ok";
        }
      });
    })();
    </script>
    """
}

private final class WebKitLivePeerCallRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result: Result<Value, Error>? = lock.withLock {
            guard !resolved else { return pending }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !resolved else { return nil }
            resolved = true
            pending = result
            let installed = self.continuation
            self.continuation = nil
            return installed
        }
        continuation?.resume(with: result)
    }
}

@MainActor
private final class SystemWebKitLivePeerEvaluator: NSObject, WebKitLivePeerScriptEvaluating, WebKitLivePeerPreparedAudioEvaluating {
    let view: WKWebView
    private let nativeMicrophoneAuthorized: @MainActor @Sendable () -> Bool
    private let pageReadiness: WebKitLivePeerPageReadiness
    private var didFinishInitialLoad = false

    init(
        nativeMicrophoneAuthorized: @escaping @MainActor @Sendable () -> Bool,
        pageLoadTimeout: Duration = .seconds(10)
    ) {
        self.nativeMicrophoneAuthorized = nativeMicrophoneAuthorized
        self.pageReadiness = WebKitLivePeerPageReadiness(timeout: pageLoadTimeout)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isInspectable = false
        view.setAccessibilityElement(false)
        view.loadHTMLString(WebKitLivePeer.localHTML, baseURL: WebKitLivePeer.baseOrigin)
    }

    func evaluate(
        _ operation: WebKitLivePeerScriptOperation,
        answer: String?
    ) async throws -> String {
        try await pageReadiness.waitUntilReady()
        let script: String
        let arguments: [String: Any]
        switch operation {
        case .prepareOffer:
            script = "return await window.millerLive.prepareOffer()"
            arguments = [:]
        case .applyAnswer:
            script = "return await window.millerLive.applyAnswer(answer)"
            guard let answer else { throw LiveAudioPeerError.invalidAnswer }
            arguments = ["answer": answer]
        case let .setMuted(muted):
            script = "return await window.millerLive.setMuted(muted)"
            arguments = ["muted": muted]
        case .connectionState:
            script = "return window.millerLive.connectionState()"
            arguments = [:]
        case .close:
            script = "return await window.millerLive.close()"
            arguments = [:]
        }
        let result = try await view.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: .page
        )
        guard let result = result as? String else { throw LiveAudioPeerError.connectionFailed }
        return result
    }

    func injectPreparedAudio(_ audio: WakeWordPreparedCommandAudio) async throws {
        try await pageReadiness.waitUntilReady()
        let payload = try Self.base64PCM(audio)
        let result = try await view.callAsyncJavaScript(
            "return await window.millerLive.injectPreparedCommandAudio(pcmBase64, sampleRate)",
            arguments: [
                "pcmBase64": payload,
                "sampleRate": audio.sampleRate,
            ],
            in: nil,
            contentWorld: .page
        )
        guard result as? String == "ok" else {
            throw LiveAudioPeerError.connectionFailed
        }
    }

    private static func base64PCM(
        _ audio: WakeWordPreparedCommandAudio
    ) throws -> String {
        guard audio.sampleRate == 16_000,
              !audio.samples.isEmpty,
              audio.samples.count <= 32_000
        else { throw LiveAudioPeerError.invalidState }
        var data = Data(capacity: audio.samples.count * MemoryLayout<Int16>.size)
        for sample in audio.samples {
            var value = UInt16(bitPattern: sample).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }
}

extension SystemWebKitLivePeerEvaluator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let decision = WebKitLivePeer.navigationDecision(
            url: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
            didFinishInitialLoad: didFinishInitialLoad
        )
        decisionHandler(decision == .allowInitialDocument ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishInitialLoad = true
        pageReadiness.finish()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        pageReadiness.fail()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        pageReadiness.fail()
    }
}

extension SystemWebKitLivePeerEvaluator: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let request: WebKitLivePeerMediaRequest
        switch type {
        case .microphone: request = .microphone
        case .camera: request = .camera
        case .cameraAndMicrophone: request = .cameraAndMicrophone
        @unknown default: request = .other
        }
        let decision = WebKitLivePeer.mediaPermissionDecision(
            nativeMicrophoneAuthorized: nativeMicrophoneAuthorized(),
            originScheme: origin.protocol,
            originHost: origin.host,
            isMainFrame: frame.isMainFrame,
            request: request
        )
        decisionHandler(decision == .grant ? .grant : .deny)
    }
}
