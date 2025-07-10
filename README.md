# iDRAC6 Nagios Plugins

Monitor the hardware health of Dell servers equipped with iDRAC6 using Nagios-compatible shell scripts. This plugin suite includes checks for:

- **Fan speeds and redundancy**
- **Voltages**
- **Temperatures**
- **Power consumption**
- **Chassis intrusion detection**

These scripts utilize `curl` and `xmllint` to query the iDRAC6 XML API over HTTPS.

> 🛠️ These checks were created because iDRAC6's SNMP interface did not expose all the necessary hardware information reliably—especially for fan redundancy, power usage, and intrusion detection.

---

## 📦 Requirements

Ensure the following dependencies are installed:

- `Bash`
- `curl`
- `xmllint` (from `libxml2-utils`)
- `bc`

### Installation

**On RHEL/CentOS:**
```
sudo yum install libxml2 bc
```

**On Debian/Ubuntu:**
```
sudo apt install libxml2-utils bc
```

---

## ✅ Available Checks

| Script                      | Description                                  |
|----------------------------|----------------------------------------------|
| `check_idrac6_fans.sh`     | Checks fan RPMs and redundancy               |
| `check_idrac6_voltages.sh` | Monitors power supply and board voltages     |
| `check_idrac6_power.sh`    | Reports real-time and average power usage    |
| `check_idrac6_amb_temp.sh` | Checks ambient system temperatures           |
| `check_idrac6_intrusion.sh`| Detects chassis intrusion status             |

---

## 🧪 Usage

Basic usage:

```
./check_idrac6_fans.sh <ip_address> <username> <password>
```

Nagios-compatible exit ```s and performance data are supported:

- `0` = OK  
- `1` = WARNING  
- `2` = CRITICAL  
- `3` = UNKNOWN  

---

## 📈 Nagios Integration

### 🔐 Secure Credential Handling

It's recommended to store your iDRAC credentials securely in `resource.cfg`:

```
$USER1$ = /usr/lib/nagios/plugins
$USER2$ = <idrac_username>
$USER3$ = <idrac_password>
```

### Define the Command

In your `commands.cfg`:

```
define command {
  command_name    check_idrac6_fans
  command_line    $USER1$/check_idrac6_fans.sh $HOSTADDRESS$ $USER2$ $USER3$
}
```

### Define the Service

Then in `services.cfg`:

```
define service {
  use                 generic-service
  host_name           my_idrac_host
  service_description Fans Status
  check_command       check_idrac6_fans
}
```

---

## 📄 License

This project is licensed under the MIT License. See the `LICENSE` file for details.

---

## 👨‍💻 Author

Maintained by **Adnan**.
