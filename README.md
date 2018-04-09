# HappyBee
### HappyBee is a companion set of features to complement ecobee Smart Thermostat
* **Instant Home/Away mode** that's immediately triggered by turning on a security camera or another device. The native away mode takes hours to be triggered, and only when the conditions are ideal
* HappyBee also **fixes a bug when HRV and furnace fan run indefinitely** when the native "Away for now" mode is triggered remotely via the ecobee app, API, IFTTT etc.
* **Humidity normalization** using a Heat Recovery Ventilator. 
* **Precise occupancy alerts** if movement was detected by one of the ecobee remote sensors (a.k.a. ["Suspicious Bees"](https://www.youtube.com/watch?v=bEwE4wyz00o&t=402))
* **Emergency alerts** when ecobee thermostat is off in cold weather, lost power or disconnected
* **Fire detection** when one or more of the remote sensors or the thermostat itself (used as heat detectors) report temperature over a set threshold. This feature could be used in conjunction with actual smoke/carbon monoxide detection by additional equipment

## Warnings, notes and known issues
* The scripts include functionality that could result in your equipment being switched off during an emergency; they are also not guaranteed to run without issues on specific hardware/software combinations or in case ecobee API is significantly updated
* The scripts could be a starting point for your development project or serve as a proof od concept, without any guarantees or warranties implied. Please see [LICENSE.md](LICENSE.md) for additional notes
* When one or more of the remote detectors is low on battery, it can report false occupancy and sometimes (rarely) a false alert may be generated 

## Getting Started
### Prerequisites and what's needed
* ecobee3 (tested) or ecobee4 thermostat with a static IP. Not recommended for ecobee lite: only a subset of the features may work
* a security camera or another device that could indicate you are away, having a static IP or DNS name on the local network until the ventilation bug is fixed and built-in ecobee "Home for now / Away for now" functionality could be used instead
* an always-on linux server, i.e. DD-WRT (tested) or OpenWRT router, Raspberry Pi etc.
* the server would need to have persistent storage (flash drive, SD card, SSD/HDD)

## Architecture
### HappyBee Software Swarm
* **waggler** is a bee that deals with auth and shares that info with other bees (i.e. pollinator)
* **pollinator** bee polls ecobee API and performs useful stuff based on various conditions
* **messenger** is a special bee that knows how to talk to humans (via email)

### Built With
[Bourne shell](https://en.wikibooks.org/wiki/Bourne_Shell_Scripting), the mother of all shells and the lowest common denominator, as it allows to run scripts on the simplest servers (i.e. BusyBox on DD-WRT routers)

## Installation & Deployment
### The exact procedure will depend on your server; open an issue or PR if Raspberry Pi support is needed.
### DD-WRT procedures are detailed in each individual script.
* Register as an ecobee developer and enroll your thermostat: https://www.ecobee.com/developers/
* Copy scripts to the server (i.e. router)
* Configure persistent storage and create a directory for tokens / occupancy state files
* Configure email parameters in the messenger.sh
* Configure crontab to run waggler and pollinator scripts on a schedule 

## Contributing
[TBD] Any feedback is welcome. Open an issue or submit a PR.

## License
* This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.
* Use of the ecobee API is subject to separate licensing terms, outlined at https://www.ecobee.com/home/developer/api/introduction/licensing-agreement.shtml

## Acknowledgments
* DD-WRT community for the messenger.sh: https://www.dd-wrt.com/phpBB2/
* Peter Mander for his amazing [Relative to Absolute Humidity conversion formula](https://carnotcycle.wordpress.com/2012/08/04/how-to-convert-relative-humidity-to-absolute-humidity/)
