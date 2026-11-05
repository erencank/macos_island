import Foundation
import os

public enum IslandLogger {
    private static let subsystem = "com.island.app"

    public static let window = Logger(subsystem: subsystem, category: "window")
    public static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    public static let hud = Logger(subsystem: subsystem, category: "hud")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let system = Logger(subsystem: subsystem, category: "system")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
