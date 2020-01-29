//
//  NotificationHelper.swift
//  MiaomiaoClient
//
//  Created by Bjørn Inge Berg on 30/05/2019.
//  Copyright © 2019 Mark Wilson. All rights reserved.
//

import AudioToolbox
import Foundation
import HealthKit
import LoopKit
import UserNotifications

enum NotificationHelper {
    private enum Identifiers: String {
        case glucocoseNotifications = "no.bjorninge.miaomiao.glucose-notification"
        case noSensorDetected = "no.bjorninge.miaomiao.nosensordetected-notification"
        case sensorChange = "no.bjorninge.miaomiao.sensorchange-notification"
        case invalidSensor = "no.bjorninge.miaomiao.invalidsensor-notification"
        case lowBattery = "no.bjorninge.miaomiao.lowbattery-notification"
        case sensorExpire = "no.bjorninge.miaomiao.SensorExpire-notification"
        case noBridgeSelected = "no.bjorninge.miaomiao.noBridgeSelected-notification"
        case bluetoothPoweredOff = "no.bjorninge.miaomiao.bluetoothPoweredOff-notification"
        case invalidChecksum = "no.bjorninge.miaomiao.invalidChecksum-notification"
        case calibrationOngoing = "no.bjorninge.miaomiao.calibration-notification"
    }

    private static var glucoseFormatterMgdl: QuantityFormatter = {
        let formatter = QuantityFormatter()
        formatter.setPreferredNumberFormatter(for: HKUnit.milligramsPerDeciliter)
        return formatter
    }()

    private static var glucoseFormatterMmol: QuantityFormatter = {
        let formatter = QuantityFormatter()
        formatter.setPreferredNumberFormatter(for: HKUnit.millimolesPerLiter)
        return formatter
    }()

    public static func vibrateIfNeeded(count: Int = 3) {
        if UserDefaults.standard.mmGlucoseAlarmsVibrate {
            vibrate(times: count)
        }
    }
    private static func vibrate(times: Int) {
        guard times >= 0 else {
            return
        }

        AudioServicesPlaySystemSoundWithCompletion(kSystemSoundID_Vibrate) {
            vibrate(times: times - 1)
        }
    }

    public static func GlucoseUnitIsSupported(unit: HKUnit) -> Bool {
        [HKUnit.milligramsPerDeciliter, HKUnit.millimolesPerLiter].contains(unit)
    }

    public static var dynamicFormatter: QuantityFormatter? {
        guard let glucoseUnit = UserDefaults.standard.mmGlucoseUnit else {
            NSLog("dabear:: glucose unit was not recognized, aborting")
            return nil
        }

        return (glucoseUnit == HKUnit.milligramsPerDeciliter ? glucoseFormatterMgdl : glucoseFormatterMmol)
    }

    public static func sendBluetoothPowerOffNotification() {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending PowerOff notification")
                return
            }
            NSLog("dabear:: sending BluetoothPowerOffNotification")

            let content = UNMutableNotificationContent()
            content.title = "Bluetooth Power Off"
            content.body = "Please turn on Bluetooth"

            addRequest(identifier: Identifiers.bluetoothPoweredOff, content: content)
        }
    }

    public static func sendNoTransmitterSelectedNotification() {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending noBridgeSelected notification")
                return
            }
            NSLog("dabear:: sending noBridgeSelected")

            let content = UNMutableNotificationContent()
            content.title = "No Libre Transmitter Selected"
            content.body = "Delete CGMManager and start anew. Your libreoopweb credentials will be preserved"

            addRequest(identifier: Identifiers.noBridgeSelected, content: content)
        }
    }

    private static func ensureCanSendGlucoseNotification(_ completion: @escaping (_ unit: HKUnit) -> Void ) {
        ensureCanSendNotification { ensured in
            if !ensured {
                return
            }
            if let glucoseUnit = UserDefaults.standard.mmGlucoseUnit, GlucoseUnitIsSupported(unit: glucoseUnit) {
                completion(glucoseUnit)
            }
        }
    }

    private static func ensureCanSendNotification(_ completion: @escaping (_ canSend: Bool) -> Void ) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if #available (iOSApplicationExtension 12.0, *) {
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    NSLog("dabear:: ensureCanSendNotification failed, authorization denied")
                    completion(false)
                    return
                }
            } else {
                // Fallback on earlier versions
                guard settings.authorizationStatus == .authorized  else {
                    NSLog("dabear:: ensureCanSendNotification failed, authorization denied")
                    completion(false)
                    return
                }
            }
            NSLog("dabear:: sending notification was allowed")
            completion(true)
        }
    }

    public static func sendInvalidChecksumIfDeveloper(_ sensorData: SensorData) {
        guard UserDefaults.standard.dangerModeActivated else {
            return
        }

        if sensorData.hasValidCRCs {
            return
        }

        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending InvalidChecksum notification due to permission problem")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Invalid libre checksum"
            content.body = "Libre sensor was incorrectly read, CRCs were not valid"

            addRequest(identifier: Identifiers.invalidChecksum, content: content)
        }
    }

    private static var glucoseNotifyCalledCount = 0

    public static func sendGlucoseNotitifcationIfNeeded(glucose: LibreGlucose, oldValue: LibreGlucose?, trend: GlucoseTrend?) {
        glucoseNotifyCalledCount &+= 1

        let shouldSendGlucoseAlternatingTimes = glucoseNotifyCalledCount != 0 && UserDefaults.standard.mmNotifyEveryXTimes != 0

        let shouldSend = UserDefaults.standard.mmAlwaysDisplayGlucose || (shouldSendGlucoseAlternatingTimes && glucoseNotifyCalledCount % UserDefaults.standard.mmNotifyEveryXTimes == 0)

        let schedules = UserDefaults.standard.glucoseSchedules

        let alarm = schedules?.getActiveAlarms(glucose.glucoseDouble) ?? .none
        let isSnoozed = GlucoseScheduleList.isSnoozed()

        NSLog("dabear:: glucose alarmtype is \(alarm)")
        // We always send glucose notifications when alarm is active,
        // even if glucose notifications are disabled in the UI

        if shouldSend || alarm.isAlarming() {
            sendGlucoseNotitifcation(glucose: glucose, oldValue: oldValue, alarm: alarm, isSnoozed: isSnoozed, trend: trend)
        } else {
            NSLog("dabear:: not sending glucose, shouldSend and alarmIsActive was false")
            return
        }
    }

    private static func addRequest(identifier: Identifiers, content: UNMutableNotificationContent, deleteOld: Bool = false) {
        let center = UNUserNotificationCenter.current()
        //content.sound = UNNotificationSound.
        let request = UNNotificationRequest(identifier: identifier.rawValue, content: content, trigger: nil)

        if deleteOld {
            // Required since ios12+ have started to cache/group notifications
            center.removeDeliveredNotifications(withIdentifiers: [identifier.rawValue])
            center.removePendingNotificationRequests(withIdentifiers: [identifier.rawValue])
        }

        center.add(request) { error in
            if let error = error {
                NSLog("dabear:: unable to addNotificationRequest: \(error.localizedDescription)")
            }
        }
    }
    private static func sendGlucoseNotitifcation(glucose: LibreGlucose, oldValue: LibreGlucose?, alarm: GlucoseScheduleAlarmResult = .none, isSnoozed: Bool = false, trend: GlucoseTrend?) {
        ensureCanSendGlucoseNotification { unit  in
            NSLog("dabear:: sending glucose notification")

            guard let formatter = dynamicFormatter, let formatted = formatter.string(from: glucose.quantity, for: unit) else {
                NSLog("dabear:: glucose unit formatter unsuccessful, aborting notification")
                return
            }
            let content = UNMutableNotificationContent()

            var titles: [String] = []
            switch alarm {
            case .none:
                titles.append("Glucose")
            case .low:
                titles.append("LOWALERT!")
            case .high:
                titles.append("HIGHALERT!")
            }

            if isSnoozed {
                titles.append("(Snoozed)")
            } else if  alarm.isAlarming() {
                content.sound = .default
                vibrateIfNeeded()
            }
            titles.append(formatted)

            content.title = titles.joined(separator: " ")
            content.body = "Glucose: \(formatted)"

            if let oldValue = oldValue {
                //these are just calculations so I can use the convenience of the glucoseformatter
                var diff = glucose.glucoseDouble - oldValue.glucoseDouble
                let sign = diff < 0 ? "-" : "+"

                if diff == 0 {
                    content.body += ", \(sign) 0"
                } else {
                    diff = abs(diff)

                    let asObj = LibreGlucose(unsmoothedGlucose: diff, glucoseDouble: diff, trend: 0, timestamp: Date(), collector: nil)
                    if let formattedDiff = formatter.string(from: asObj.quantity, for: unit) {
                        content.body += ", " + sign + formattedDiff
                    }
                }
            }

            if let trend = trend?.localizedDescription {
                content.body += ", \(trend)"
            }

            addRequest(identifier: Identifiers.glucocoseNotifications, content: content, deleteOld: true)
        }
    }

    public static func sendCalibrationNotification(_ calibrationMessage: String) {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending sendCalibration notification")
                return
            }
            NSLog("dabear:: sending sendCalibrationNotification")

            let content = UNMutableNotificationContent()
            content.sound = .default
            content.title = "Extracting calibrationdata from sensor"
            content.body = calibrationMessage

            addRequest(identifier: Identifiers.calibrationOngoing,
                       content: content,
                       deleteOld: true)
        }
    }

    public static func sendSensorNotDetectedNotificationIfNeeded(noSensor: Bool, devicename: String) {
        guard UserDefaults.standard.mmAlertNoSensorDetected && noSensor else {
            NSLog("not sending noSensorDetected notification")
            return
        }

        sendSensorNotDetectedNotification(devicename: devicename)
    }

    private static func sendSensorNotDetectedNotification(devicename: String) {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending noSensorDetected notification")
                return
            }
            NSLog("dabear:: sending noSensorDetected")

            let content = UNMutableNotificationContent()
            content.title = "No Sensor Detected"
            content.body = "This might be an intermittent problem, but please check that your \(devicename) is tightly secured over your sensor"

            addRequest(identifier: Identifiers.noSensorDetected, content: content)
        }
    }

    public static func sendSensorChangeNotificationIfNeeded() {
        guard UserDefaults.standard.mmAlertNewSensorDetected else {
            NSLog("not sending sendSensorChange notification ")
            return
        }
        sendSensorChangeNotification()
    }

    private static func sendSensorChangeNotification() {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending sensorChangeNotification notification")
                return
            }
            NSLog("dabear:: sending sensorChangeNotification")

            let content = UNMutableNotificationContent()
            content.title = "New Sensor Detected"
            content.body = "Please wait up to 30 minutes before glucose readings are available!"

            addRequest(identifier: Identifiers.sensorChange, content: content)
            //content.sound = UNNotificationSound.

        }
    }

    public static func sendInvalidSensorNotificationIfNeeded(sensorData: SensorData) {
        let isValid = sensorData.isLikelyLibre1 && (sensorData.state == .starting || sensorData.state == .ready)

        guard UserDefaults.standard.mmAlertInvalidSensorDetected && !isValid else {
            NSLog("not sending invalidSensorDetected notification")
            return
        }

        sendInvalidSensorNotification(sensorData: sensorData)
    }

    private static func sendInvalidSensorNotification(sensorData: SensorData) {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending InvalidSensorNotification notification")
                return
            }

            NSLog("dabear:: sending InvalidSensorNotification")

            let content = UNMutableNotificationContent()
            content.title = "Invalid Sensor Detected"

            if !sensorData.isLikelyLibre1 {
                content.body = "Detected sensor seems not to be a libre 1 sensor!"
            } else if !(sensorData.state == .starting || sensorData.state == .ready) {
                content.body = "Detected sensor is invalid: \(sensorData.state.description)"
            }

            content.sound = .default

            addRequest(identifier: Identifiers.invalidSensor, content: content)
        }
    }

    private static var lastBatteryWarning: Date?

    public static func sendLowBatteryNotificationIfNeeded(device: LibreTransmitterMetadata) {
        guard UserDefaults.standard.mmAlertLowBatteryWarning else {
            NSLog("mmAlertLowBatteryWarning toggle was not enabled, not sending low notification")
            return
        }

        guard device.battery <= 20 else {
            NSLog("device battery is \(device.batteryString), not sending low notification")
            return
        }

        let now = Date()
        //only once per mins minute
        let mins = 60.0 * 120
        if let earlier = lastBatteryWarning {
            let earlierplus = earlier.addingTimeInterval(mins)
            if earlierplus < now {
                sendLowBatteryNotification(batteryPercentage: device.batteryString, deviceName: device.name)
                lastBatteryWarning = now
            } else {
                NSLog("Device battery is running low, but lastBatteryWarning Notification was sent less than 45 minutes ago, aborting. earlierplus: \(earlierplus), now: \(now)")
            }
        } else {
            sendLowBatteryNotification(batteryPercentage: device.batteryString, deviceName: device.name)
            lastBatteryWarning = now
        }
    }

    private static func sendLowBatteryNotification(batteryPercentage: String, deviceName: String) {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending LowBattery notification")
                return
            }
            NSLog("dabear:: sending LowBattery notification")

            let content = UNMutableNotificationContent()
            content.title = "Low Battery"
            content.body = "Battery is running low (\(batteryPercentage)), consider charging your \(deviceName) device as soon as possible"

            content.sound = .default

            addRequest(identifier: Identifiers.lowBattery, content: content)
        }
    }

    private static var lastSensorExpireAlert: Date?

    public static func sendSensorExpireAlertIfNeeded(sensorData: SensorData) {
        guard UserDefaults.standard.mmAlertWillSoonExpire else {
            NSLog("mmAlertWillSoonExpire toggle was not enabled, not sending expiresoon alarm")
            return
        }

        guard sensorData.minutesSinceStart >= 19_440 else {
            NSLog("sensor start was less than 13,5 days in the past, not sending notification: \(sensorData.minutesSinceStart) minutes / \(sensorData.humanReadableSensorAge)")
            return
        }

        let now = Date()
        //only once per 6 hours
        let min45 = 60.0 * 60 * 6
        if let earlier = lastSensorExpireAlert {
            if earlier.addingTimeInterval(min45) < now {
                sendSensorExpireAlert(sensorData: sensorData)
                lastSensorExpireAlert = now
            } else {
                NSLog("Sensor is soon expiring, but lastSensorExpireAlert was sent less than 6 hours ago, so aborting")
            }
        } else {
            sendSensorExpireAlert(sensorData: sensorData)
            lastSensorExpireAlert = now
        }
    }

    private static func sendSensorExpireAlert(sensorData: SensorData) {
        ensureCanSendNotification { ensured in
            guard ensured else {
                NSLog("dabear:: not sending SensorExpireAlert notification")
                return
            }
            NSLog("dabear:: sending SensorExpireAlert notification")

            let content = UNMutableNotificationContent()
            content.title = "Sensor Ending Soon"
            content.body = "Current Sensor is Ending soon! Sensor Age: \(sensorData.humanReadableSensorAge)"

            addRequest(identifier: Identifiers.sensorExpire, content: content)
        }
    }
}
