# MedtrumKit

Medtrum Bluetooth PumpManager For Loop.

## Supported Medtrum versions
- 200U (both MD0201 & MD8201)
- 300U (MD8301)

## Connection

MedtrumKit connects to the patch on demand: for a command or a status read, then it hangs up about 4 s after the last one. The link stays up while a bolus runs (its progress only arrives as notifications), while a patch is set up, and while the app needs the pump as its heartbeat (a CGM that can't wake the loop). Alarms such as an occlusion or an expired patch are therefore seen at the next connect, within one loop cycle; the patch beeps by itself in the meantime.

## Handing the patch to another controller (Watch Loop)

`MedtrumPumpManager` implements LoopKit's `DeviceConfigurationSharing`, `ExclusiveDeviceControl` and `PumpDeliveryOdometer`, as OmnipodKit does (loopandlearn/OmnipodKit#177). The export carries the pump base's serial number and session token and the doses in flight; each device keeps its own Bluetooth handle in `localState`, and a device without one finds the base by its serial number. The delivered total is what the patch has given since its first reservoir reading, in 0.05 U pulses. The `MedtrumKit-watchOS` target builds the kit without its UI for the watch.

## For more information

Please join loop zulipchat at https://loop.zulipchat.com/

Or the Trio discord at https://discord.gg/FnwFEFUwXE
