import CoreWLAN
import Foundation

let client = CWWiFiClient.shared()
guard let iface = client.interface() else {
    print("STATUS=off")
    exit(0)
}

let rssi = iface.rssiValue()
let noise = iface.noiseMeasurement()
let ch = iface.wlanChannel()
let chNum = ch?.channelNumber ?? 0
let bandRaw = ch?.channelBand.rawValue ?? 0
let txRate = iface.transmitRate()

let band: String
switch bandRaw {
case 1: band = "2.4GHz"
case 2: band = "5GHz"
case 3: band = "6GHz"
default: band = "Unknown"
}

print("STATUS=on")
print("RSSI=\(rssi)")
print("NOISE=\(noise)")
print("CHANNEL=\(chNum)")
print("BAND=\(band)")
print("TX_RATE=\(Int(txRate))")
