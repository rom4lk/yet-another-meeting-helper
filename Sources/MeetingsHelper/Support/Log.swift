import OSLog

enum Log {
    private static let subsystem = "com.kovalev.MeetingsHelper"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let detection = Logger(subsystem: subsystem, category: "detection")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let asr = Logger(subsystem: subsystem, category: "asr")
    static let store = Logger(subsystem: subsystem, category: "store")
}
