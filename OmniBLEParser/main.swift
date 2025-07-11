//
//  main.swift
//  OmniBLEParser
//
//  Based on OmniKitPacketParser/main.swift
//  Created by Joseph Moran on 02/02/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation

// The following default values can all be forced to false or to true using the -q and -v command line options respectively
fileprivate var printDate: Bool = true // whether to print the date (when available) along with the time (when available)
fileprivate var printUnacknowledgedMessageLines: Bool = true // whether to print "Unacknowledged message" lines
fileprivate var printAddressAndSeq: Bool = false // whether to print full message decode including the pod address and seq #
fileprivate var printPodConnectionLines: Bool = false // whether to print "connection Pod" lines


//from NSHipster - http://nshipster.com/swift-literal-convertible/
struct Regex {
    let pattern: String
    let options: NSRegularExpression.Options!

    private var matcher: NSRegularExpression {
        return try! NSRegularExpression(pattern: self.pattern, options: self.options)
    }

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        self.pattern = pattern
        self.options = options
    }

    func match(string: String, options: NSRegularExpression.MatchingOptions = []) -> Bool {
        return self.matcher.numberOfMatches(in: string, options: options, range: NSMakeRange(0, string.count)) != 0
    }
}

protocol RegularExpressionMatchable {
    func match(regex: Regex) -> Bool
}

extension String: RegularExpressionMatchable {
    func match(regex: Regex) -> Bool {
        return regex.match(string: self)
    }
}

func ~=<T: RegularExpressionMatchable>(pattern: Regex, matchable: T) -> Bool {
    return matchable.match(regex: pattern)
}

extension String {
    func subString(location: Int, length: Int? = nil) -> String {
      let start = min(max(0, location), self.count)
      let limitedLength = min(self.count - start, length ?? Int.max)
      let from = index(startIndex, offsetBy: start)
      let to = index(startIndex, offsetBy: start + limitedLength)
      return String(self[from..<to])
    }
}

func printDecoded(dateStr: String, timeStr: String, hexStr: String)
{
    guard let data = Data(hexadecimalString: hexStr), data.count >= 10 else {
        print("Bad hex string: \(hexStr)")
        return
    }
    do {
        // The block type is right after the 4-byte address and the B9 and BLEN bytes
        guard let blockType = MessageBlockType(rawValue: data[6]) else {
            throw MessageBlockError.unknownBlockType(rawVal: data[6])
        }
        let type: String
        let checkCRC: Bool
        switch blockType {
        case .statusResponse, .podInfoResponse, .versionResponse, .errorResponse:
            type = "RESPONSE: "
            // Don't currently understand how to check the CRC16 the DASH pods generate
            checkCRC = false
        default:
            type = "COMMAND:  "
            checkCRC = true
        }
        let message = try Message(encodedData: data, checkCRC: checkCRC)
        var dateTimeStr: String
        if printDate && !dateStr.isEmpty {
            dateTimeStr = dateStr + " " + timeStr + " "
        } else if !timeStr.isEmpty {
            dateTimeStr = timeStr + " "
        } else {
            dateTimeStr = ""
        }
        if printAddressAndSeq {
            // print the complete message with the address and seq
            print("\(type)\(dateTimeStr)\(message)")
        } else {
            // skip printing the address and seq for each message
            print("\(type)\(dateTimeStr)\(message.messageBlocks)")
        }
    } catch let error {
        print("Could not parse \(hexStr): \(error)")
    }
}

// * 2022-04-05 06:56:14 +0000 Omnipod-Dash 17CAE1DD send 17cae1dd00030e010003b1
// * 2022-04-05 06:56:14 +0000 Omnipod-Dash 17CAE1DD receive 17cae1dd040a1d18002ab00000019fff0198
func parseLoopReportLine(line: String) {
    let components = line.components(separatedBy: .whitespaces)
    let hexString = components[components.count - 1]

    printDecoded(dateStr: components[1], timeStr: components[2], hexStr: hexString)
}

// Older Xcode log file with inline metadata
// 2023-02-02 15:23:13.094289-0800 Loop[60606:22880823] [PodMessageTransport] Send(Hex): 1776c2c63c030e010000a0
// 2023-02-02 15:23:13.497849-0800 Loop[60606:22880823] [PodMessageTransport] Recv(Hex): 1776c2c6000a1d180064d800000443ff0000
func parseLoopXcodeInlineMetadataLine(line: String) {
    let components = line.components(separatedBy: .whitespaces)
    let hexString = components[components.count - 1]

    let time = components[1].subString(location: 0, length: 15) // use the 15 detailed time chars w/o TZ (e.g., "15:23:13.497849")

    printDecoded(dateStr: components[0], timeStr: time, hexStr: hexString)
}

// Newer Xcode log file using separate metadata lines (app independent)
// Send(Hex): 1f074dca1c201a0ea814ef4e01007901384000000000160e000000006b49d20000006b49d200013a
// Timestamp: 2024-01-14 12:02:27.095438-08:00 | Library: OmniKit | Category: PodMessageTransport
// Recv(Hex): 1f074dca200a1d280059b800001aa7ff01c0
// Timestamp: 2024-01-14 12:02:30.391271-08:00 | Library: OmniKit | Category: PodMessageTransport
func parseXcodeLine(line: String, timestampLine: String) {
    var date = ""
    var time = ""

    let timeStampLineComponents = timestampLine.components(separatedBy: .whitespaces)
    if timeStampLineComponents.count >= 3 {
        for i in 0...timeStampLineComponents.count - 2 {
            if timeStampLineComponents[i] == "Timestamp:" {
                date = timeStampLineComponents[i + 1]
                time = timeStampLineComponents[i + 2].subString(location: 0, length: 15) // use the 15 detailed time chars w/o TZ
                break
            }
        }
    }

    let components = line.components(separatedBy: .whitespaces)
    let hexString = components[components.count - 1]

    printDecoded(dateStr: date, timeStr: time, hexStr: hexString)
}

// N.B. Simulator output typically has a space after the hex string!
// INFO[7699] pkg command; 0x0e; GET_STATUS; HEX, 1776c2c63c030e010000a0
// INFO[7699] pkg response 0x1d; HEX, 1776c2c6000a1d280064e80000057bff0000
// INFO[2023-09-04T18:17:06-07:00] pkg command; 0x07; GET_VERSION; HEX, ffffffff00060704ffffffff82b2
// INFO[2023-09-04T18:17:06-07:00] pkg response 0x1; HEX, ffffffff04170115040a00010300040208146db10006e45100ffffffff0000
func parseSimulatorLogLine(line: String) {
    let components = line.components(separatedBy: .whitespaces)
    var hexStringIndex = components.count - 1
    let hexString: String
    if components[hexStringIndex].isEmpty {
        hexStringIndex -= 1 // back up to handle a trailing space
    }
    hexString = components[hexStringIndex]

    let c0 = components[0]
    let date: String
    let time: String

    if c0.count <= 16 {
        // seconds only format, e.g., "INFO[7699]"
        date = ""
        time = c0.subString(location: 5, length: c0.count - 6) // six less for the "INFO[]" chars
    } else {
        // full time format, e.g., "INFO[2023-09-04T18:17:06-07:00]"
        date = c0.subString(location: 5, length: 10)
        time = c0.subString(location: 16, length: 8) // the time w/o TZ (e.g., "18:17:06")
    }

    printDecoded(dateStr: date, timeStr: time, hexStr: hexString)
}


// FreeAPS style log file or Xcode log file with inline metadata
// 2024-05-08T00:03:57-0700 [DeviceManager] DeviceDataManager.swift - deviceManager(_:logEventForDeviceIdentifier:type:message:completion:) - 576 - DEV: Device message: 17ab48aa20071f05494e532e0201d5
func parseFreeAPSLogOrXcodeInlineMetadataLine(line: String) {
    let components = line.components(separatedBy: .whitespaces)
    let hexString = components[components.count - 1]
    let date, time: String

    if components.count > 9 {
        // have a timestamp like "2024-05-08T00:03:57-0700" or "2024-05-25" "14:16:54.933281-0700"
        date = components[0].subString(location: 0, length: 10) // the first 10 chars are the date (e.g,. "2024-05-25")
        if components[0].contains("T") {
            // iAPS or Trio log file with date and time joined with a "T", e.g., "2024-05-25T00:26:05-0700"
            time = components[0].subString(location: 11, length: 8) // the 8 time chars w/o TZ (e.g., "00:26:05")
        } else {
            // Xcode log file with separate date and time, e.g., "2024-05-25" "14:16:53.571361-0700"
            time = components[1].subString(location: 0, length: 15)  // the 15 detailed time chars w/o TZ (e.g., "14:16:53.571361")
        }
    } else {
        // no timestamp
        date = ""
        time = ""
    }
    printDecoded(dateStr: date, timeStr: time, hexStr: hexString)
}

// 2020-11-04 13:38:34.256  1336  6945 I PodComm pod command: 08202EAB08030E01070319
// 2020-11-04 13:38:34.979  1336  1378 V PodComm response (hex) 08202EAB0C0A1D9800EB80A400042FFF8320
func parseDashPDMLogLine(line: String) {
    let components = line.components(separatedBy: .whitespaces)
    let hexString = components[components.count - 1]

    printDecoded(dateStr: components[0], timeStr: components[1], hexStr: hexString)
}

// Disconnect and connect messages
//
// Loop Report
// * 2024-07-09 23:10:17 +0000 Omnipod-Dash 170C4026 connection Pod disconnected 80635530-69E1-E701-9C57-190CC608CE6F Optional(Error Domain=CBErrorDomain Code=7 "The specified device has disconnected from us." UserInfo={NSLocalizedDescription=The specified device has disconnected from us.})
// iAPS or Trio log file
// 2024-05-25T00:05:22-0700 [DeviceManager] DeviceDataManager.swift - deviceManager(_:logEventForDeviceIdentifier:type:message:completion:) - 576 - DEV: Device message: Pod connected C8AA0FAE-7BF3-D682-38D7-DD7314F0F128
//
// Loop xcode log
// 2024-05-25 14:04:19.799014-0700 Loop[2042:132457] [PersistentDeviceLog] connection (17FC3D73) Pod disconnected 86779FC4-EB9B-6ED6-6A38-C345BE12FDB6 nil
// iAPS or Trio xcode log
// 2024-05-25 14:22:47.988314-0700 FreeAPS[2973:2299227] [DeviceManager] DeviceDataManager.swift - deviceManager(_:logEventForDeviceIdentifier:type:message:completion:) - 566 DEV: Device message: Pod connected F74B4012-5849-3E00-792E-66726A675CED
//
// With newer Xcode logging, metadata could be on a separate line (app independent)
//
// Unacknowledged messages
// Old style
// * 2024-07-09 23:25:25 +0000 Omnipod-Dash 170C4026 error Unacknowledged message. seq:10, error = ...
// Newer styles
// * 2024-07-09 23:25:25 +0000 Omnipod-Dash 170C4026 error Unacknowledged message sending command seq:11, error = ...
// * 2024-07-09 23:25:25 +0000 Omnipod-Dash 170C4026 error Unacknowledged message reading response for sent command seq:12, error = ...
func printPodInfoLine(line: String, timestampLine: String) {
    let components = line.components(separatedBy: .whitespaces)
    var endIndex = components.endIndex - 1
    var startIndex = components[0] == "*" ? 1 : 0   // skip any leading "*"

    var date = ""
    var time = ""
    let timeStampLineComponents = timestampLine.components(separatedBy: .whitespaces)
    if timeStampLineComponents.count >= 3 {
        // newer Xcode logging with a separate line for metadata
        for i in 0...timeStampLineComponents.count - 2 {
            if timeStampLineComponents[i] == "Timestamp:" {
                date = timeStampLineComponents[i + 1]
                time = timeStampLineComponents[i + 2].subString(location: 0, length: 15) // use the 15 detailed time chars w/o TZ
                break
            }
        }
    } else if components[startIndex].contains("T") {
        // iAPS or Trio log file with date and time with TZ joined with a 'T', e.g., "2024-05-25T00:26:05-0700"
        date = components[startIndex].subString(location: 0, length: 10) // the first 10 chars are date (e.g., "2024-05-25")
        time = components[startIndex].subString(location: 11, length: 8) // the 8 time chars w/o TZ (e.g., "00:26:05)
        startIndex += 1
    } else if components[startIndex + 1].contains(".") {
        // Xcode log file with separate date and precise time with TZ, e.g., "2024-05-25" "14:16:53.571361-0700"
        date = components[startIndex]
        time = components[1].subString(location: 0, length: 15)  // the 15 detailed time chars w/o TZ (e.g., "14:16:53.571361")
        startIndex += 2
    } else if components[startIndex + 2].hasPrefix("+") {
        // Loop log file with separate date, time & timezone, e.g., "2023-04-05" "06:07:08" "+0000"
        date = components[startIndex]
        time = components[startIndex + 1]
        startIndex += 3
    }

    // Trim the fat to simplify the output depending on whether it's a connection or unacknowledged message
    for i in startIndex...endIndex {
        // For disconnected & connected messages, only keep 2 words
        if components[i].contains("disconnected") || components[i].contains("connected") && i > 1 {
            startIndex = i - 1 // "Pod"
            endIndex = i // "disconnected" or "connected"
            break
        }
        if components[i].contains("Unacknowledged") {
            startIndex = i // strip earlier cruft
            break
        }
    }

    var podInfoLine = "          " // aligns with "RESPONSE: " or "COMMAND:  " prefixes
    if printDate && !date.isEmpty {
        podInfoLine += date + " "
    }
    if !time.isEmpty {
        podInfoLine += time + " "
    }

    for i in startIndex...endIndex {
        podInfoLine += components[i]
        if i < endIndex {
            podInfoLine += " "
        }
    }
    print(podInfoLine)
}

func usage() {
    print("Usage: [-qv] file...")
    print("Set the Xcode Arguments Passed on Launch using Product->Scheme->Edit Scheme...")
    print("to specify the full path to Loop Report, Xcode log, pod simulator log, iAPS log, Trio log or DASH PDM log file(s) to parse.\n")
    exit(1)
}

if CommandLine.argc <= 1 {
    usage()
}

for arg in CommandLine.arguments[1...] {
    if arg == "-q" {
        printDate = false
        printUnacknowledgedMessageLines = false
        printAddressAndSeq = false
        printPodConnectionLines = false
        continue
    } else if arg == "-v" {
        printDate = true
        printUnacknowledgedMessageLines = true
        printAddressAndSeq = true
        printPodConnectionLines = true
        continue
    } else if arg == "" || arg == "--" {
        continue
    } else if arg.starts(with: "-") {
        // no other arguments curently supported
        usage()
    }

    var timestampLine: String
    print("\nParsing \(arg)")
    do {
        let data = try String(contentsOfFile: arg, encoding: .utf8)
        let lines = data.components(separatedBy: .newlines)

        for i in 0..<lines.count {
            let line = lines[i]

            // New style Xcode metadata logging can have optional timestamp info on a separate line
            // Send(Hex): 1f074dca1c201a0ea814ef4e01007901384000000000160e000000006b49d20000006b49d200013a
            // Timestamp: 2024-01-14 12:02:27.095438-08:00 | Library: OmniKit | Category: PodMessageTransport
            // Recv(Hex): 1f074dca200a1d280059b800001aa7ff01c0
            // Timestamp: 2024-01-14 12:02:30.391271-08:00 | Library: OmniKit | Category: PodMessageTransport
            if i < lines.count - 1 && lines[i + 1].contains("Timestamp:") {
                timestampLine = lines[i + 1]
            } else {
                timestampLine = ""
            }

            switch line {
            // Loop Report file
            // * 2022-04-05 06:56:14 +0000 Omnipod-Dash 17CAE1DD send 17cae1dd00030e010003b1
            // * 2022-04-05 06:56:14 +0000 Omnipod-Dash 17CAE1DD receive 17cae1dd040a1d18002ab00000019fff0198
            case Regex("(send|receive) [0-9a-fA-F]+$"):
                parseLoopReportLine(line: line)

            // Older Xcode log file with inline metadata
            // 2023-02-02 15:23:13.094289-0800 Loop[60606:22880823] [PodMessageTransport] Send(Hex): 1776c2c63c030e010000a0
            // 2023-02-02 15:23:13.497849-0800 Loop[60606:22880823] [PodMessageTransport] Recv(Hex): 1776c2c6000a1d180064d800000443ff0000
            case Regex(" Loop\\[.*\\] \\[PodMessageTransport\\] (Send|Recv)\\(Hex\\): [0-9a-fA-F]+$"):
                parseLoopXcodeInlineMetadataLine(line: line)

            // Newer Xcode log file using separate metadata lines (app independent)
            // Send(Hex): 1f074dca1c201a0ea814ef4e01007901384000000000160e000000006b49d20000006b49d200013a
            // Recv(Hex): 1f074dca200a1d280059b800001aa7ff01c0
            case Regex("(Send|Recv)\\(Hex\\): [0-9a-fA-F]+$"):
                parseXcodeLine(line: line, timestampLine: timestampLine)

            // FreeAPS style log file or Xcode log file with inline metadata
            // 2024-05-08T00:03:57-0700 [DeviceManager] DeviceDataManager.swift - deviceManager(_:logEventForDeviceIdentifier:type:message:completion:) - 576 - DEV: Device message: 17ab48aa20071f05494e532e0201d5
            case Regex("Device message: [0-9a-fA-F]+$"):
                parseFreeAPSLogOrXcodeInlineMetadataLine(line: line)

            // Simulator log file (N.B. typically has a trailing space!)
            // INFO[7699] pkg command; 0x0e; GET_STATUS; HEX, 1776c2c63c030e010000a0
            // INFO[7699] pkg response 0x1d; HEX, 1776c2c6000a1d280064e80000057bff0000
            case Regex("; HEX, [0-9a-fA-F]+ $"), Regex("; HEX, [0-9a-fA-F]+$"):
                parseSimulatorLogLine(line: line)

            // DASH PDM log file
            // 2020-11-04 21:35:52.218  1336  1378 I PodComm pod command: 08202EAB30030E010000BC
            // 2020-11-04 21:35:52.575  1336  6945 V PodComm response (hex) 08202EAB340A1D18018D2000000BA3FF81D9
            case Regex("I PodComm pod command: "), Regex("V PodComm response \\(hex\\) "):
                parseDashPDMLogLine(line: line)

            // Pod disconnected/Pod connected messages from either log or xcode log file
            // Loop
            // * 2024-07-09 23:10:17 +0000 Omnipod-Dash 170C4026 connection Pod disconnected 80635530-69E1-E701-9C57-190CC608CE6F Optional(Error Domain=CBErrorDomain Code=7 "The specified device has disconnected from us." UserInfo={NSLocalizedDescription=The specified device has disconnected from us.})
            // * 2024-07-09 23:10:21 +0000 Omnipod-Dash 170C4026 connection Pod connected 80635530-69E1-E701-9C57-190CC608CE6F
            // iAPS or Trio
            // 2024-05-25T00:05:21-0700 [DeviceManager] DeviceDataManager.swift - deviceManager(_:logEventForDeviceIdentifier:type:message:completion:) - 576 - DEV: Device message: Pod disconnected C8AA0FAE-7BF3-D682-38D7-DD7314F0F128 Optional(Error Domain=CBErrorDomain Code=7 "The specified device has disconnected from us." UserInfo={NSLocalizedDescription=The specified device has disconnected from us.})
            // 2024-05-25T00:05:22-0700 [DeviceManager] DeviceDataManager.swift - deviceManager(_:logEventForDeviceIdentifier:type:message:completion:) - 576 - DEV: Device message: Pod connected C8AA0FAE-7BF3-D682-38D7-DD7314F0F128
            case Regex(" Pod disconnected "), Regex(" Pod connected "):
                if printPodConnectionLines {
                    printPodInfoLine(line: line, timestampLine: timestampLine)
                }

            // Unacknowledged messages lines from either a log or xcode log file
            // Older style unacknowledged message error
            // * 2024-07-09 23:25:25 +0000 Omnipod-Dash 170C4026 error Unacknowledged message. seq:10, error = ...
            // Newer style unacknowledged message errors
            // * 2024-07-09 23:25:25 +0000 Omnipod-Dash 170C4026 error Unacknowledged message sending command seq:11, error = ...
            // * 2024-07-09 23:25:25 +0000 Omnipod-Dash 170C4026 error Unacknowledged message reading response for sent command seq:12, error = ...
            case Regex(" Unacknowledged message"):
                if printUnacknowledgedMessageLines {
                    printPodInfoLine(line: line, timestampLine: timestampLine)
                }

            default:
                break
            }
        }
    } catch let error {
        print("Error: \(error)")
    }
    print("\n")
}
