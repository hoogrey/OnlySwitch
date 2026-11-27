import AVFoundation
import Foundation

/// Tracks rendered PCM rather than the mixer tap, which also runs when it is rendering silence.
@MainActor
final class StreamerAudibleObservation {
    enum State { case buffering, playing, ended, unavailable }

    private let onChange: (State) -> Void
    private var scheduledBuffers = 0
    private var lastRender: ContinuousClock.Instant?
    private var state: State?

    init(onChange: @escaping (State) -> Void) {
        self.onChange = onChange
    }

    func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) {
        scheduledBuffers += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduledBuffers -= 1
                self.lastRender = .now
                self.report(.playing)
            }
        }
    }

    func update(inputComplete: Bool, schedulingComplete: Bool) {
        if inputComplete, schedulingComplete, scheduledBuffers == 0 {
            report(lastRender == nil ? .unavailable : .ended)
        } else if lastRender == nil || (scheduledBuffers == 0
                    && (lastRender?.duration(to: .now) ?? .zero) >= .milliseconds(250)) {
            report(.buffering)
        }
    }

    func report(_ state: State) {
        guard self.state != state else { return }
        self.state = state
        onChange(state)
    }
}
