import Foundation

/// One held utterance on its way to ElevenLabs Scribe Realtime: a websocket from the phone, text frames only.
/// The protocol and buffering live in `ScribeTurn`; this adds the socket and the timeouts. Main thread only.
final class ScribeListener: NSObject, URLSessionWebSocketDelegate {
    static let connectTimeout = 5.0
    static let startTimeout = 4.0
    static let finalTimeout = 8.0

    /// `.final` and `.failed` come once; the socket is closed by then.
    var onEvent: ((ScribeTurn.Event) -> Void)?
    /// `session_started` arrived (for timings).
    var onStarted: (() -> Void)?

    private var turn = ScribeTurn()
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var isStarted = false
    private var isReleased = false
    private var timeout: DispatchWorkItem?

    init(token: String, keyterms: [String]) {
        url = ScribeRealtime.socketURL(token: token, keyterms: keyterms, languageCode: nil)
        super.init()
    }

    func start() {
        guard task == nil, !closed else { return }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.connectTimeout
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        arm(Self.connectTimeout)
        receive(on: task)
    }

    /// Held audio (24 kHz PCM16 mono). Buffered until Scribe says it's ready.
    func send(_ pcm: Data) {
        guard !closed else { return }
        transmit(turn.audio(pcm))
    }

    /// Let go: commits the turn. `.tooShort` and `.overflowed` close the socket and no event follows.
    func release() -> ScribeTurn.Release {
        guard !closed else { return .wait }
        let result = turn.release()
        switch result {
        case .send(let frames):
            isReleased = true
            transmit(frames)
            arm(Self.finalTimeout)
        case .wait:
            // Not started yet: the connect and start timeouts keep running, and the commit goes out with `session_started`.
            isReleased = true
        case .tooShort, .overflowed:
            close()
        }
        return result
    }

    /// Abandons the turn without an event.
    func cancel() { close() }

    // MARK: Socket

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed, task === self.task else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.fail("connection")
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = ScribeRealtime.parse(text) else { return }
        if message == .sessionStarted {
            isStarted = true
            if isReleased { arm(Self.finalTimeout) } else { timeout?.cancel(); timeout = nil }
            transmit(turn.started())
            onStarted?()
        }
        guard let event = turn.receive(message) else { return }
        if case .partial = event { onEvent?(event); return }
        close()
        onEvent?(event)
    }

    private func transmit(_ frames: [String]) {
        guard let task else { return }
        for frame in frames {
            task.send(.string(frame)) { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { self?.fail("connection") }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, !self.isStarted else { return }
            self.arm(Self.startTimeout)
        }
    }

    // MARK: Timeouts

    private func arm(_ seconds: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail("timeout") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fail(_ type: String) {
        guard !closed else { return }
        close()
        onEvent?(.failed(type))
    }

    private func close() {
        closed = true
        timeout?.cancel()
        timeout = nil
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
