import Foundation
// Posts an automation command to a running MacBud (launched with MACBUD_AUTOMATION=1).
// Usage: mbctl "open?section=clipboard"   mbctl "key?seq=down,return"   mbctl "dump?path=/tmp/d.json"
guard CommandLine.arguments.count > 1 else { FileHandle.standardError.write(Data("usage: mbctl '<command>?<query>'\n".utf8)); exit(1) }
DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.rangrik.macbud.automation"),
                                                             object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
