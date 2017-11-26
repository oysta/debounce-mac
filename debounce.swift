import Foundation
import AppKit

let syntheticKeyboardId = 666

func tapHandler(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    
    let debouncer: DebouncerTap = Unmanaged.fromOpaque(userInfo!).takeUnretainedValue()
    
    switch type {
        
    case .tapDisabledByTimeout:
        NSLog("event tap has timed out, re-enabling tap")
        debouncer.tapEvents()
        return nil
        
    case .tapDisabledByUserInput:
        break
        
    default:
        let keyboardId = event.getIntegerValueField(.keyboardEventKeyboardType)
        if keyboardId == syntheticKeyboardId {
            break
        }
        
        let foundationEvent = NSEvent(cgEvent: event)!
        
        if debouncer.debounce(foundationEvent) == .drop {
            return nil
        }
    }
    
    return Unmanaged.passUnretained(event)
}

final class DebouncerTap: NSObject {
    
    var eventTap: CFMachPort?
    
    var outstandingStrokes: [NSEvent] = []
    
    let debounceInterval: TimeInterval
    
    private var interrupted: Bool = false
    
    let dispatchSelector = #selector(DebouncerTap.dispatch(event:))
    
    var isTapActive: Bool {
        guard let eventTap = eventTap else {
            return false
        }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }
    
    init(interval: TimeInterval) {
        self.debounceInterval = interval
    }
    
    deinit {
        detach()
    }
    
    func interrupt() {
        self.interrupted = true
    }
    
    func detach() {
        guard let eventTap = eventTap else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        RunLoop.current.remove(eventTap, forMode: .commonModes)
        self.eventTap = nil
    }
    
    @objc func dispatch(event: NSEvent) {
        guard let index = outstandingStrokes.index(of: event)
            else {
                NSLog("No outstanding stroke found")
                return
        }
        outstandingStrokes.remove(at: index)
        event.cgEvent!.post(tap: .cgAnnotatedSessionEventTap)
    }
    
    enum DebounceResult {
        case pass
        case drop
    }
    
    func debounce(_ event: NSEvent) -> DebounceResult {
        
        if event.isARepeat {
            return .pass
        }
        
        switch event.type {
            
        case .keyDown:
            outstandingStrokes.append(event)
            self.perform(dispatchSelector, with: event, afterDelay: debounceInterval)
            return .drop
            
        case .keyUp:
            guard let index = outstandingStrokes.index(where: { $0.keyCode == event.keyCode })
                else {
                    return .pass
            }
            
            let outstanding = outstandingStrokes[index]
            
            NSLog("Key bounce detected: \(outstanding.characters ?? "<<nil>>")")
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: dispatchSelector,
                object: outstanding
            )
            outstandingStrokes.remove(at: index)
            return .drop

        default:
            NSLog("Unexpected event type")
        }
        
        return .pass
    }
    
    @discardableResult
    func tapEvents() -> Bool {
        if eventTap == nil {
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue),
                callback: tapHandler,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }
        
        guard let eventTap = eventTap else {
            NSLog("Unable to create tap; run as root or grant assistive access")
            return false
        }
        
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return self.isTapActive
    }
    
    func attach() {
        if eventTap == nil {
            tapEvents()
        }
        
        guard let eventTap = eventTap else {
            return
        }
        
        RunLoop.current.add(eventTap, forMode: .commonModes)
        while !self.interrupted {
            RunLoop.current.run(mode: .defaultRunLoopMode, before: Date.distantFuture)
        }
        self.interrupted = false
        detach()
    }
    
}

let debounceInterval: TimeInterval

if CommandLine.arguments.count < 2 {
    debounceInterval = 0.05
}
else {
    guard let providedIntervalInMs = Int(CommandLine.arguments[1]) else {
        print("Bad debounce interval; specify as integral milliseconds")
        exit(1)
    }
    debounceInterval = TimeInterval(Double(providedIntervalInMs) / 1000.0)
}

let debouncer = DebouncerTap(interval: debounceInterval)

signal(SIGINT) { _ in debouncer.interrupt() }

debouncer.attach()
