# Zimbra Migration Scripts

## Enhanced Zimbra Export and Import Scripts with Progress Tracking and Resume Capability

Comprehensive scripts for migrating Zimbra mail server data between servers with advanced features including progress tracking, resume capability, and detailed logging.

---

## 📋 Table of Contents / İçindekiler

- [English](#english)
  - [Features](#features)
  - [Requirements](#requirements)
  - [Installation](#installation)
  - [Usage](#usage)
  - [Export Script](#export-script)
  - [Import Script](#import-script)
  - [Resume Capability](#resume-capability)
  - [Progress Tracking](#progress-tracking)
  - [Logging](#logging)
  - [Troubleshooting](#troubleshooting)
- [Türkçe](#türkçe)
  - [Özellikler](#özellikler)
  - [Gereksinimler](#gereksinimler)
  - [Kurulum](#kurulum)
  - [Kullanım](#kullanım)
  - [Export Script](#export-script-1)
  - [Import Script](#import-script-1)
  - [Devam Etme Özelliği](#devam-etme-özelliği)
  - [İlerleme Takibi](#ilerleme-takibi)
  - [Loglama](#loglama)
  - [Sorun Giderme](#sorun-giderme)

---

# English

## Features

### ✨ Key Features

- **Progress Tracking**: Real-time progress bars with percentage, elapsed time, and ETA
- **Resume Capability**: Automatically resumes from where it left off if interrupted
- **Parallel Processing**: Email import runs with 10 concurrent jobs for faster migration
- **Silent Operation**: imapsync runs silently - clean screen output during email import
- **Detailed Logging**: Comprehensive logging to file with timestamps
- **Failed User Reports**: Detailed reports of failed imports at the end (screen + log)
- **Ctrl+C Support**: Gracefully stops all processes when interrupted
- **Color-coded Output**: Easy-to-read colored terminal output
- **Error Handling**: Robust error handling with detailed error messages
- **Modular Design**: Each import/export step is a separate function
- **Terminal Adaptive**: Progress bars adapt to terminal width
- **State Management**: Tracks completed items to avoid duplicates

### 📦 Export Features

- Export all domains or specific domain
- Export user accounts and passwords
- Export contacts, calendars, and briefcase
- Export mail filters and signatures
- Export autoresponders and forwarders
- Export aliases and distribution lists
- Export user preferences and settings
- Export shared resources and legal intercepts

### 📥 Import Features

- Import domains and users
- Import contacts, calendars, and briefcase
- Import mail filters and signatures
- Import autoresponders and forwarders
- Import aliases and distribution lists
- Import user preferences and settings
- Import shared resources and legal intercepts
- Email migration via imapsync

## Requirements

### System Requirements

- **Operating System**: Linux (tested on RHEL, CentOS, Ubuntu)
- **Zimbra Version**: Zimbra Collaboration Suite 8.x or later
- **Permissions**: Root access required
- **Disk Space**: Sufficient space for backup directory (typically 2-3x mailbox size)

### Software Requirements

- **Bash**: Version 4.0 or later
- **Zimbra Tools**: zmprov, zmmailbox (included with Zimbra)
- **imapsync**: Required for email migration (install separately)
- **rsync**: Required for data transfer (usually pre-installed)
- **Standard Tools**: grep, awk, sed, cut (usually pre-installed)

### Installing imapsync

```bash
# On RHEL/CentOS
sudo yum install imapsync

# On Ubuntu/Debian
sudo apt-get install imapsync

# Or compile from source
# Visit: https://imapsync.lamiral.info/
```

## Installation

1. **Clone or download the scripts**:
   ```bash
   cd /usr/local/src
   # Or your preferred location
   ```

2. **Set execute permissions**:
   ```bash
   chmod +x export_zimbra.sh
   chmod +x import_zimbra.sh
   ```

3. **Verify Zimbra installation**:
   ```bash
   sudo -u zimbra /opt/zimbra/bin/zmprov --version
   ```

4. **Create backup directory** (optional, script creates it automatically):
   ```bash
   sudo mkdir -p /opt/zmbackup
   sudo chown -R zimbra:zimbra /opt/zmbackup
   ```

## How It Works / Çalışma Mantığı

### Migration Workflow / Göç İş Akışı

The migration process consists of two main steps that run on different servers:

Göç süreci, farklı sunucularda çalışan iki ana adımdan oluşur:

```
┌─────────────────────────────────────────────────────────────────┐
│                    STEP 1: EXPORT (ESKİ SUNUCU)                 │
│                    Export Script Execution                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Creates backup files
                              │ /opt/zmbackup/
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Backup Directory Structure:                                    │
│  ├── domains.txt                                                │
│  ├── emails.txt                                                 │
│  ├── userpass/ (encrypted passwords)                            │
│  ├── contacts/, calendars/, briefcase/                          │
│  └── ... (all exported data)                                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ rsync transfer
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    STEP 2: IMPORT (YENİ SUNUCU)                │
│                    Import Script Execution                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Imports to local Zimbra
                              │ (localhost)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  New Zimbra Server:                                             │
│  ├── Domains created                                            │
│  ├── Users created with passwords                               │
│  ├── Contacts, calendars, emails imported                       │
│  └── All settings and preferences restored                      │
└─────────────────────────────────────────────────────────────────┘
```

### Where Scripts Run / Script'lerin Çalıştığı Yerler

#### Export Script (`export_zimbra.sh`)

**Location / Konum**: **OLD Zimbra Server / ESKİ Zimbra Sunucusu**

- Runs on the source server where data will be exported from
- Creates backup files in `/opt/zmbackup/` directory
- Does NOT modify the source server, only reads data

- Verilerin export edileceği kaynak sunucuda çalışır
- `/opt/zmbackup/` dizininde yedek dosyaları oluşturur
- Kaynak sunucuyu değiştirmez, sadece veri okur

**Example / Örnek**:
```bash
# On OLD Zimbra server / ESKİ Zimbra sunucusunda
ssh root@old-zimbra-server
cd /usr/local/src
sudo ./export_zimbra.sh
```

#### Import Script (`import_zimbra.sh`)

**Location / Konum**: **NEW Zimbra Server / YENİ Zimbra Sunucusu**

- Runs on the destination server where data will be imported to
- Uses `rsync` to fetch backup files from the old server
- Executes `zmprov` and `zmmailbox` commands on **localhost** (local Zimbra)
- Uses `imapsync` with `--host2 localhost` to import emails to local server

- Verilerin import edileceği hedef sunucuda çalışır
- Eski sunucudan yedek dosyalarını `rsync` ile çeker
- **localhost** (yerel Zimbra) üzerinde `zmprov` ve `zmmailbox` komutlarını çalıştırır
- Emailleri yerel sunucuya import etmek için `imapsync` ile `--host2 localhost` kullanır

**Example / Örnek**:
```bash
# On NEW Zimbra server / YENİ Zimbra sunucusunda
ssh root@new-zimbra-server
cd /usr/local/src
sudo ./import_zimbra.sh <OLD_SERVER_IP>
```

### Detailed Process Flow / Detaylı İşlem Akışı

#### Export Process / Export Süreci

1. **On OLD Server / ESKİ Sunucuda**:
   ```bash
   sudo ./export_zimbra.sh
   ```
   - Reads all Zimbra data using `zmprov` and `zmmailbox`
   - Saves to `/opt/zmbackup/` directory
   - Creates state files for resume capability
   - Does NOT modify source server

   - `zmprov` ve `zmmailbox` kullanarak tüm Zimbra verilerini okur
   - `/opt/zmbackup/` dizinine kaydeder
   - Devam etme özelliği için durum dosyaları oluşturur
   - Kaynak sunucuyu değiştirmez

#### Import Process / Import Süreci

1. **On NEW Server / YENİ Sunucuda**:
   ```bash
   sudo ./import_zimbra.sh <OLD_SERVER_IP>
   ```

2. **Step 1: Data Sync / Veri Senkronizasyonu**:
   ```bash
   rsync -azlgop root@<OLD_SERVER_IP>:/opt/zmbackup/ /opt/zmbackup/
   ```
   - Fetches backup files from old server
   - Eski sunucudan yedek dosyalarını çeker

3. **Step 2: Import Operations / Import İşlemleri**:
   ```bash
   # All these run on LOCALHOST (new server)
   sudo -u zimbra /opt/zimbra/bin/zmprov cd domain.com    # Create domain
   sudo -u zimbra /opt/zimbra/bin/zmprov ca user@domain.com ...  # Create user
   sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m user@domain.com ...  # Import data
   ```
   - All `zmprov` and `zmmailbox` commands target **localhost**
   - All operations modify the **NEW Zimbra server**

   - Tüm `zmprov` ve `zmmailbox` komutları **localhost**'u hedefler
   - Tüm işlemler **YENİ Zimbra sunucusunu** değiştirir

4. **Step 3: Email Migration / Email Göçü**:
   ```bash
   imapsync \
     --host1 <OLD_SERVER_IP> \    # Source: OLD server
     --host2 localhost \          # Destination: NEW server (local)
     --user1 user@domain.com \
     --user2 user@domain.com \
     ...
   ```
   - Reads emails from OLD server (`--host1`)
   - Writes emails to NEW server (`--host2 localhost`)

   - Eski sunucudan emailleri okur (`--host1`)
   - Yeni sunucuya emailleri yazar (`--host2 localhost`)



### Network Requirements / Ağ Gereksinimleri

- **From NEW to OLD / YENİ'den ESKİ'ye**:
  - SSH access (for rsync) / SSH erişimi (rsync için)
  - IMAP/IMAPS access (for imapsync) / IMAP/IMAPS erişimi (imapsync için)
  - Port 22 (SSH) and 993 (IMAPS) should be open / Port 22 (SSH) ve 993 (IMAPS) açık olmalı

- **From OLD to NEW / ESKİ'den YENİ'ye**:
  - No direct connection needed / Doğrudan bağlantı gerekmez
  - NEW server pulls data / YENİ sunucu veriyi çeker

## Usage

### Export Script

#### Basic Usage

```bash
# Export all domains
sudo ./export_zimbra.sh

# Export specific domain
sudo ./export_zimbra.sh example.com
```

#### Export Process

1. **Initialization**: Script checks for previous sessions and offers resume option
2. **Domain Export**: Exports domain list
3. **User Export**: Exports user account list
4. **Password Export**: Exports user passwords (encrypted)
5. **User Data Export**: Exports user account information
6. **Contacts Export**: Exports contacts in CSV format
7. **Filters Export**: Exports mail filter rules
8. **Signatures Export**: Exports email signatures
9. **Autoresponders Export**: Exports out-of-office messages
10. **Aliases Export**: Exports email aliases
11. **Forwarders Export**: Exports mail forwarding rules
12. **Settings Export**: Exports user preferences and settings
13. **Briefcase Export**: Exports briefcase files
14. **Calendar Export**: Exports calendar events
15. **Distribution Lists Export**: Exports distribution lists
16. **Global Settings Export**: Exports global server settings
17. **Catch-all Export**: Exports catch-all account settings

#### Export Output Structure

```
/opt/zmbackup/
├── .export_state/          # State files for resume capability
│   ├── progress.txt        # Current progress information
│   └── *_completed.txt    # Completed items per step
├── export.log              # Detailed log file
├── domains.txt             # List of domains
├── emails.txt              # List of email addresses
├── admins.txt              # List of admin accounts
├── distribution_list.txt   # List of distribution lists
├── global_settings.txt     # Global server settings
├── userpass/               # User passwords (encrypted)
│   └── user@domain.com.shadow
├── userdata/               # User account data
│   └── user@domain.com.txt
├── contacts/               # Contacts in CSV format
│   └── user@domain.com.csv
├── filters/               # Mail filter rules
│   └── user@domain.com.txt
├── signatures/             # Email signatures
│   └── user@domain.com.txt
├── autoresponders/         # Out-of-office messages
│   ├── user@domain.com.txt
│   └── user@domain.com_reply.txt
├── alias/                  # Email aliases
│   └── user@domain.com.txt
├── forwarders/             # Mail forwarding rules
│   ├── user@domain.com_hidden.txt
│   └── user@domain.com_userdefined.txt
├── settings/               # User preferences and settings
│   ├── user@domain.com_folders.txt
│   ├── user@domain.com_prefs.txt
│   ├── user@domain.com_shared.txt
│   ├── user@domain.com_intercept.txt
│   ├── user@domain.com_status.txt
│   └── user@domain.com_catchall.txt
├── briefcase/              # Briefcase files
│   └── user@domain.com/
│       └── *.tgz
├── calendar/               # Calendar events
│   └── user@domain.com/
│       └── *.tgz
├── distribution/           # Distribution list data
│   └── list@domain.com.txt
└── catchall/               # Catch-all account settings
    └── domain.com.txt
```

### Import Output Structure

After import, the following structure is created:

```
/opt/zmbackup/
├── .import_state/          # State files for resume capability
│   ├── progress.txt        # Current progress information
│   └── *_completed.txt    # Completed items per step
├── import.log              # Detailed log file
├── imapsync_logs/          # Individual imapsync log files (NEW)
│   ├── user1@domain.com.log
│   ├── user2@domain.com.log
│   └── ...
├── .sync_completed         # Flag indicating data sync completed
└── ... (all imported data from export)
```

### Import Script

#### Basic Usage

```bash
# Import from source server
sudo ./import_zimbra.sh <source_server_ip>

# Import from source server with custom backup directory
sudo ./import_zimbra.sh <source_server_ip> /path/to/backup

# Email-only mode (only sync emails, skip all other steps)
sudo ./import_zimbra.sh <source_server_ip> /opt/zmbackup --email-only
```

#### Import Process

1. **Data Sync**: rsync data from source server
2. **Domain Import**: Import domains
3. **User Import**: Import user accounts with passwords
4. **Signatures Import**: Import email signatures
5. **Autoresponders Import**: Import out-of-office messages
6. **Filters Import**: Import mail filter rules
7. **Contacts Import**: Import contacts
8. **Calendar Import**: Import calendar events
9. **Briefcase Import**: Import briefcase files
10. **Forwarders Import**: Import mail forwarding rules
11. **Aliases Import**: Import email aliases
12. **Distribution Lists Import**: Import distribution lists
13. **Email Import**: Import emails via imapsync (with enhanced features)
14. **Preferences Import**: Import user preferences
15. **Legal Intercepts Import**: Import legal intercept settings
16. **Share Settings Import**: Import shared resources
17. **User Status Import**: Import user account status
18. **Post-Import Email Re-sync**: Option to sync new emails that arrived during migration

#### Email-Only Mode

The `--email-only` flag allows you to run only the email import step, skipping all other import operations. This is useful for:

- Syncing new emails that arrived after the initial migration
- Re-syncing emails without running the full import process
- Quick email synchronization

```bash
# Run only email import
sudo ./import_zimbra.sh <source_server_ip> /opt/zmbackup --email-only
```

#### Enhanced imapsync Features

The email import process includes several enhancements:

- **Parallel Processing**: Processes up to 10 email accounts simultaneously for faster migration
- **Silent Operation**: imapsync runs completely silently - no output to screen during processing
- **Individual Log Files**: Each user's email sync is logged to `${BACKUP_DIR}/imapsync_logs/${email}.log`
- **User Validation**: Checks if user exists on destination server before attempting sync
- **Retry Mechanism**: Automatically retries failed syncs up to 3 times with 10-second delays
- **Timeout Protection**: 120-second timeouts to prevent hanging connections
- **Error Detection**: Analyzes log files for errors and warnings
- **Password Security**: Admin passwords are cleared from memory after use
- **Version Display**: Shows imapsync version at start
- **Failed User Report**: Detailed report of failed email imports at the end (both on screen and in log file)
- **Ctrl+C Support**: Press Ctrl+C to immediately stop all imapsync processes gracefully

#### Post-Import Email Re-sync

After completing all import steps, the script offers to sync emails again to catch any new emails that arrived on the old server during the migration process:

```
Note: If new emails arrived on the old server during migration,
you can sync them again now.

Do you want to sync emails again (to catch any new emails)? (y/n):
```

This feature:
- Only syncs emails (skips other import steps)
- Uses resume capability (only syncs missing/new emails)
- Shows progress with progress bar
- Tracks sync time separately

#### Import Requirements

- **Source Server Access**: Root SSH access to source server
- **Network Connectivity**: Stable network connection
- **imapsync**: Installed and configured
- **Admin Passwords**: Required for email migration (entered securely)

## Resume Capability

### How It Works

The scripts maintain state files in `.export_state` or `.import_state` directories. Each completed item is tracked, allowing the script to resume from where it left off.

### Resuming Export

```bash
# If export is interrupted, simply run again
sudo ./export_zimbra.sh

# Script will detect previous session and ask:
# "Previous export session detected!
#  Last progress: Passwords - 415/926
#  Resume from where you left off? (y/n)"
```

### Resuming Import

```bash
# If import is interrupted, simply run again
sudo ./import_zimbra.sh <source_server_ip>

# Script will detect previous session and ask:
# "Previous import session detected!
#  Last progress: Users - 415/926
#  Resume from where you left off? (y/n)"
```

### State Files

State files are stored in:
- Export: `/opt/zmbackup/.export_state/`
- Import: `/opt/zmbackup/.import_state/`

Each step has its own completion file:
- `passwords_completed.txt` - Completed password exports
- `users_completed.txt` - Completed user imports
- etc.

### Starting Fresh

To start fresh (ignore previous progress):
```bash
# Answer 'n' when asked about resuming
# Or manually delete state files:
sudo rm -rf /opt/zmbackup/.export_state/*
sudo rm -rf /opt/zmbackup/.import_state/*
```

## Progress Tracking

### Progress Bar Display

The scripts display real-time progress information:

```
Passwords [==========>] 45% (415/926) | 00:05:23 | ETA: 00:06:15 | user@domain.com
```

- **Progress Bar**: Visual representation of completion
- **Percentage**: Current completion percentage
- **Count**: Current item / Total items
- **Elapsed Time**: Time since start (HH:MM:SS)
- **ETA**: Estimated time remaining (HH:MM:SS)
- **Current Item**: Currently processing item (truncated if long)

### Terminal Adaptation

Progress bars automatically adapt to terminal width:
- **Narrow terminals** (<100 chars): Compact display
- **Standard terminals** (100-120 chars): Standard display
- **Wide terminals** (>120 chars): Extended display

### Progress Information

Progress information is saved to:
- Export: `/opt/zmbackup/.export_state/progress.txt`
- Import: `/opt/zmbackup/.import_state/progress.txt`

Format: `step_name|current|total|percent|timestamp`

## Logging

### Log Files

- **Export Log**: `/opt/zmbackup/export.log`
- **Import Log**: `/opt/zmbackup/import.log`

### Log Format

```
[2024-01-15 10:30:45] [INFO] Starting export step: passwords
[2024-01-15 10:30:46] [INFO] Total items: 926 | Already exported: 0 | Remaining: 926
[2024-01-15 10:35:12] [INFO] ✓ passwords completed | Processed: 926/926
[2024-01-15 10:35:13] [ERROR] Failed to export: user@domain.com
```

### Log Levels

- **INFO**: General information messages
- **ERROR**: Error messages and failures
- **WARNING**: Warning messages (not currently used)

### Viewing Logs

```bash
# View export log
tail -f /opt/zmbackup/export.log

# View import log
tail -f /opt/zmbackup/import.log

# Search for errors
grep ERROR /opt/zmbackup/export.log

# View last 100 lines
tail -n 100 /opt/zmbackup/export.log
```

## Troubleshooting

### Common Issues

#### 1. Permission Denied

**Error**: `Permission denied` or `Cannot access`

**Solution**:
```bash
# Ensure script is executable
chmod +x export_zimbra.sh import_zimbra.sh

# Ensure running as root
sudo ./export_zimbra.sh

# Check Zimbra user permissions
sudo -u zimbra /opt/zimbra/bin/zmprov -l gaa
```

#### 2. State Directory Issues

**Error**: State files not being created

**Solution**:
```bash
# Manually create state directory
sudo mkdir -p /opt/zmbackup/.export_state
sudo mkdir -p /opt/zmbackup/.import_state
sudo chown -R zimbra:zimbra /opt/zmbackup
```

#### 3. Progress Bar Not Displaying

**Error**: Progress bar shows escape codes or doesn't update

**Solution**:
- Ensure terminal supports ANSI colors
- Check terminal width: `tput cols`
- Use a modern terminal emulator

#### 4. Resume Not Working

**Error**: Script doesn't detect previous session

**Solution**:
```bash
# Check state files exist
ls -la /opt/zmbackup/.export_state/

# Check progress file
cat /opt/zmbackup/.export_state/progress.txt

# Verify file permissions
sudo chown -R zimbra:zimbra /opt/zmbackup/.export_state
```

#### 5. imapsync Not Found

**Error**: `imapsync does not exist`

**Solution**:
```bash
# Install imapsync
# On RHEL/CentOS:
sudo yum install imapsync

# On Ubuntu/Debian:
sudo apt-get install imapsync

# Verify installation
which imapsync

# Check version
imapsync --version
```

#### 5a. imapsync Log Files

**Location**: Individual log files are created for each user in `${BACKUP_DIR}/imapsync_logs/`

**Viewing logs**:
```bash
# View log for specific user
cat /opt/zmbackup/imapsync_logs/user@domain.com.log

# Search for errors across all logs
grep -r "ERROR\|FATAL" /opt/zmbackup/imapsync_logs/

# View last 50 lines of a log
tail -n 50 /opt/zmbackup/imapsync_logs/user@domain.com.log
```

#### 5b. Email-Only Mode

**Usage**: Run only email import without other import steps

```bash
# Sync only emails
sudo ./import_zimbra.sh <source_server_ip> /opt/zmbackup --email-only
```

**Use cases**:
- Sync new emails that arrived after initial migration
- Re-sync emails without full import
- Quick email synchronization

#### 6. rsync Connection Issues

**Error**: `rsync: connection refused` or `Permission denied`

**Solution**:
```bash
# Test SSH connection
ssh root@source_server_ip

# Test rsync manually
rsync -azlgop root@source_server_ip:/opt/zmbackup/ /tmp/test/

# Ensure SSH keys are set up (optional but recommended)
ssh-copy-id root@source_server_ip
```

#### 7. Zimbra Command Failures

**Error**: `zmprov: command not found` or `zmmailbox: command not found`

**Solution**:
```bash
# Verify Zimbra installation
sudo -u zimbra /opt/zimbra/bin/zmprov --version

# Check Zimbra user
id zimbra

# Ensure running as root
sudo ./export_zimbra.sh
```

### Performance Tips

1. **Use screen or tmux**: Prevents disconnection issues
   ```bash
   screen -S zimbra_migration
   sudo ./export_zimbra.sh
   # Press Ctrl+A then D to detach
   ```

2. **Monitor disk space**: Ensure sufficient space
   ```bash
   df -h /opt/zmbackup
   ```

3. **Network optimization**: For large migrations, ensure stable network
   ```bash
   # Test network speed
   iperf3 -c source_server_ip
   ```

4. **Resource monitoring**: Monitor system resources
   ```bash
   # Monitor CPU and memory
   top
   # Or
   htop
   ```

### Best Practices

1. **Test First**: Test with a single domain or small user set
2. **Backup First**: Always backup before migration
3. **Use Screen**: Use screen or tmux for long-running processes
4. **Monitor Logs**: Monitor log files during migration
5. **Verify Data**: Verify exported data before import
6. **Staged Migration**: Consider migrating in stages (domains, users, emails)

---

# Türkçe

## Özellikler

### ✨ Temel Özellikler

- **İlerleme Takibi**: Yüzde, geçen süre ve tahmini kalan süre ile gerçek zamanlı ilerleme çubukları
- **Devam Etme Özelliği**: Kesintiye uğrarsa kaldığı yerden otomatik devam eder
- **Paralel İşleme**: Email import 10 eşzamanlı işle birlikte çalışır (daha hızlı göç)
- **Sessiz Çalışma**: imapsync sessiz çalışır - email import sırasında temiz ekran çıktısı
- **Detaylı Loglama**: Zaman damgalı kapsamlı log dosyası
- **Başarısız Kullanıcı Raporları**: İşlem sonunda başarısız import'lar için detaylı raporlar (ekran + log)
- **Ctrl+C Desteği**: Kesintiye uğradığında tüm süreçleri zarif bir şekilde durdurur
- **Renkli Çıktı**: Okunması kolay renkli terminal çıktısı
- **Hata Yönetimi**: Detaylı hata mesajları ile sağlam hata yönetimi
- **Modüler Tasarım**: Her import/export adımı ayrı bir fonksiyon
- **Terminal Uyumlu**: İlerleme çubukları terminal genişliğine uyum sağlar
- **Durum Yönetimi**: Tamamlanan öğeleri takip ederek tekrarları önler

### 📦 Export Özellikleri

- Tüm domainleri veya belirli bir domaini export etme
- Kullanıcı hesapları ve şifreleri export etme
- Kişiler, takvimler ve dosya çantası export etme
- Mail filtreleri ve imzalar export etme
- Otomatik yanıtlar ve yönlendirmeler export etme
- Takma adlar ve dağıtım listeleri export etme
- Kullanıcı tercihleri ve ayarları export etme
- Paylaşılan kaynaklar ve yasal dinlemeler export etme

### 📥 Import Özellikleri

- Domain ve kullanıcı import etme
- Kişiler, takvimler ve dosya çantası import etme
- Mail filtreleri ve imzalar import etme
- Otomatik yanıtlar ve yönlendirmeler import etme
- Takma adlar ve dağıtım listeleri import etme
- Kullanıcı tercihleri ve ayarları import etme
- Paylaşılan kaynaklar ve yasal dinlemeler import etme
- imapsync ile email göçü

## Gereksinimler

### Sistem Gereksinimleri

- **İşletim Sistemi**: Linux (RHEL, CentOS, Ubuntu'da test edilmiştir)
- **Zimbra Sürümü**: Zimbra Collaboration Suite 8.x veya üzeri
- **İzinler**: Root erişimi gerekir
- **Disk Alanı**: Yedek dizini için yeterli alan (genellikle mailbox boyutunun 2-3 katı)

### Yazılım Gereksinimleri

- **Bash**: Sürüm 4.0 veya üzeri
- **Zimbra Araçları**: zmprov, zmmailbox (Zimbra ile birlikte gelir)
- **imapsync**: Email göçü için gerekli (ayrı yüklenir)
- **rsync**: Veri transferi için gerekli (genellikle önceden yüklüdür)
- **Standart Araçlar**: grep, awk, sed, cut (genellikle önceden yüklüdür)

### imapsync Kurulumu

```bash
# RHEL/CentOS'ta
sudo yum install imapsync

# Ubuntu/Debian'da
sudo apt-get install imapsync

# Veya kaynaktan derle
# Ziyaret: https://imapsync.lamiral.info/
```

## Kurulum

1. **Script'leri klonlayın veya indirin**:
   ```bash
   cd /usr/local/src
   # Veya tercih ettiğiniz konum
   ```

2. **Çalıştırma izinlerini ayarlayın**:
   ```bash
   chmod +x export_zimbra.sh
   chmod +x import_zimbra.sh
   ```

3. **Zimbra kurulumunu doğrulayın**:
   ```bash
   sudo -u zimbra /opt/zimbra/bin/zmprov --version
   ```

4. **Yedek dizini oluşturun** (isteğe bağlı, script otomatik oluşturur):
   ```bash
   sudo mkdir -p /opt/zmbackup
   sudo chown -R zimbra:zimbra /opt/zmbackup
   ```

## Çalışma Mantığı

### Göç İş Akışı

Göç süreci, farklı sunucularda çalışan iki ana adımdan oluşur:

```
┌─────────────────────────────────────────────────────────────────┐
│                    ADIM 1: EXPORT (ESKİ SUNUCU)                 │
│                    Export Script Çalıştırma                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Yedek dosyaları oluşturur
                              │ /opt/zmbackup/
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Yedek Dizin Yapısı:                                            │
│  ├── domains.txt                                                │
│  ├── emails.txt                                                 │
│  ├── userpass/ (şifrelenmiş şifreler)                           │
│  ├── contacts/, calendars/, briefcase/                          │
│  └── ... (tüm export edilen veriler)                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ rsync transfer
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ADIM 2: IMPORT (YENİ SUNUCU)                 │
│                    Import Script Çalıştırma                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Yerel Zimbra'ya import eder
                              │ (localhost)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Yeni Zimbra Sunucusu:                                          │
│  ├── Domainler oluşturuldu                                      │
│  ├── Kullanıcılar şifrelerle oluşturuldu                        │
│  ├── Kişiler, takvimler, emailler import edildi                 │
│  └── Tüm ayarlar ve tercihler geri yüklendi                     │
└─────────────────────────────────────────────────────────────────┘
```

### Script'lerin Çalıştığı Yerler

#### Export Script (`export_zimbra.sh`)

**Konum**: **ESKİ Zimbra Sunucusu**

- Verilerin export edileceği kaynak sunucuda çalışır
- `/opt/zmbackup/` dizininde yedek dosyaları oluşturur
- Kaynak sunucuyu değiştirmez, sadece veri okur

**Örnek**:
```bash
# ESKİ Zimbra sunucusunda
ssh root@eski-zimbra-sunucu
cd /usr/local/src
sudo ./export_zimbra.sh
```

#### Import Script (`import_zimbra.sh`)

**Konum**: **YENİ Zimbra Sunucusu**

- Verilerin import edileceği hedef sunucuda çalışır
- Eski sunucudan yedek dosyalarını `rsync` ile çeker
- **localhost** (yerel Zimbra) üzerinde `zmprov` ve `zmmailbox` komutlarını çalıştırır
- Emailleri yerel sunucuya import etmek için `imapsync` ile `--host2 localhost` kullanır

**Örnek**:
```bash
# YENİ Zimbra sunucusunda
ssh root@yeni-zimbra-sunucu
cd /usr/local/src
sudo ./import_zimbra.sh <ESKİ_SUNUCU_IP>
```

### Detaylı İşlem Akışı

#### Export Süreci

1. **ESKİ Sunucuda**:
   ```bash
   sudo ./export_zimbra.sh
   ```
   - `zmprov` ve `zmmailbox` kullanarak tüm Zimbra verilerini okur
   - `/opt/zmbackup/` dizinine kaydeder
   - Devam etme özelliği için durum dosyaları oluşturur
   - Kaynak sunucuyu değiştirmez

#### Import Süreci

1. **YENİ Sunucuda**:
   ```bash
   sudo ./import_zimbra.sh <ESKİ_SUNUCU_IP>
   ```

2. **Adım 1: Veri Senkronizasyonu**:
   ```bash
   rsync -azlgop root@<ESKİ_SUNUCU_IP>:/opt/zmbackup/ /opt/zmbackup/
   ```
   - Eski sunucudan yedek dosyalarını çeker

3. **Adım 2: Import İşlemleri**:
   ```bash
   # Tüm bunlar LOCALHOST (yeni sunucu) üzerinde çalışır
   sudo -u zimbra /opt/zimbra/bin/zmprov cd domain.com    # Domain oluştur
   sudo -u zimbra /opt/zimbra/bin/zmprov ca user@domain.com ...  # Kullanıcı oluştur
   sudo -u zimbra /opt/zimbra/bin/zmmailbox -z -m user@domain.com ...  # Veri import et
   ```
   - Tüm `zmprov` ve `zmmailbox` komutları **localhost**'u hedefler
   - Tüm işlemler **YENİ Zimbra sunucusunu** değiştirir

4. **Adım 3: Email Göçü**:
   ```bash
   imapsync \
     --host1 <ESKİ_SUNUCU_IP> \    # Kaynak: ESKİ sunucu
     --host2 localhost \            # Hedef: YENİ sunucu (yerel)
     --user1 user@domain.com \
     --user2 user@domain.com \
     ...
   ```
   - Eski sunucudan emailleri okur (`--host1`)
   - Yeni sunucuya emailleri yazar (`--host2 localhost`)



### Ağ Gereksinimleri

- **YENİ'den ESKİ'ye**:
  - SSH erişimi (rsync için)
  - IMAP/IMAPS erişimi (imapsync için)
  - Port 22 (SSH) ve 993 (IMAPS) açık olmalı

- **ESKİ'den YENİ'ye**:
  - Doğrudan bağlantı gerekmez
  - YENİ sunucu veriyi çeker

## Kullanım

### Export Script

#### Temel Kullanım

```bash
# Tüm domainleri export et
sudo ./export_zimbra.sh

# Belirli bir domaini export et
sudo ./export_zimbra.sh example.com
```

#### Export Süreci

1. **Başlatma**: Script önceki oturumları kontrol eder ve devam etme seçeneği sunar
2. **Domain Export**: Domain listesini export eder
3. **Kullanıcı Export**: Kullanıcı hesap listesini export eder
4. **Şifre Export**: Kullanıcı şifrelerini export eder (şifrelenmiş)
5. **Kullanıcı Verisi Export**: Kullanıcı hesap bilgilerini export eder
6. **Kişi Export**: Kişileri CSV formatında export eder
7. **Filtre Export**: Mail filtresi kurallarını export eder
8. **İmza Export**: Email imzalarını export eder
9. **Otomatik Yanıt Export**: Mesai dışı mesajlarını export eder
10. **Takma Ad Export**: Email takma adlarını export eder
11. **Yönlendirme Export**: Mail yönlendirme kurallarını export eder
12. **Ayarlar Export**: Kullanıcı tercihleri ve ayarlarını export eder
13. **Dosya Çantası Export**: Dosya çantası dosyalarını export eder
14. **Takvim Export**: Takvim etkinliklerini export eder
15. **Dağıtım Listesi Export**: Dağıtım listelerini export eder
16. **Global Ayarlar Export**: Global sunucu ayarlarını export eder
17. **Catch-all Export**: Catch-all hesap ayarlarını export eder

#### Export Çıktı Yapısı

```
/opt/zmbackup/
├── .export_state/          # Devam etme özelliği için durum dosyaları
│   ├── progress.txt        # Mevcut ilerleme bilgisi
│   └── *_completed.txt    # Adım başına tamamlanan öğeler
├── export.log              # Detaylı log dosyası
├── domains.txt             # Domain listesi
├── emails.txt              # Email adresi listesi
├── admins.txt              # Admin hesap listesi
├── distribution_list.txt   # Dağıtım listesi listesi
├── global_settings.txt     # Global sunucu ayarları
├── userpass/               # Kullanıcı şifreleri (şifrelenmiş)
│   └── user@domain.com.shadow
├── userdata/               # Kullanıcı hesap verisi
│   └── user@domain.com.txt
├── contacts/               # CSV formatında kişiler
│   └── user@domain.com.csv
├── filters/               # Mail filtresi kuralları
│   └── user@domain.com.txt
├── signatures/             # Email imzaları
│   └── user@domain.com.txt
├── autoresponders/         # Mesai dışı mesajları
│   ├── user@domain.com.txt
│   └── user@domain.com_reply.txt
├── alias/                  # Email takma adları
│   └── user@domain.com.txt
├── forwarders/             # Mail yönlendirme kuralları
│   ├── user@domain.com_hidden.txt
│   └── user@domain.com_userdefined.txt
├── settings/               # Kullanıcı tercihleri ve ayarları
│   ├── user@domain.com_folders.txt
│   ├── user@domain.com_prefs.txt
│   ├── user@domain.com_shared.txt
│   ├── user@domain.com_intercept.txt
│   ├── user@domain.com_status.txt
│   └── user@domain.com_catchall.txt
├── briefcase/              # Dosya çantası dosyaları
│   └── user@domain.com/
│       └── *.tgz
├── calendar/               # Takvim etkinlikleri
│   └── user@domain.com/
│       └── *.tgz
├── distribution/           # Dağıtım listesi verisi
│   └── list@domain.com.txt
└── catchall/               # Catch-all hesap ayarları
    └── domain.com.txt
```

### Import Çıktı Yapısı

Import sonrası aşağıdaki yapı oluşturulur:

```
/opt/zmbackup/
├── .import_state/          # Devam etme özelliği için durum dosyaları
│   ├── progress.txt        # Mevcut ilerleme bilgisi
│   └── *_completed.txt    # Adım başına tamamlanan öğeler
├── import.log              # Detaylı log dosyası
├── imapsync_logs/          # Ayrı imapsync log dosyaları (YENİ)
│   ├── user1@domain.com.log
│   ├── user2@domain.com.log
│   └── ...
├── .sync_completed         # Veri senkronizasyonunun tamamlandığını gösteren bayrak
└── ... (export'tan gelen tüm import edilen veriler)
```

### Import Script

#### Temel Kullanım

```bash
# Kaynak sunucudan import et
sudo ./import_zimbra.sh <kaynak_sunucu_ip>

# Özel yedek dizini ile kaynak sunucudan import et
sudo ./import_zimbra.sh <kaynak_sunucu_ip> /yol/yedek

# Sadece email modu (sadece emailleri senkronize et, diğer adımları atla)
sudo ./import_zimbra.sh <kaynak_sunucu_ip> /opt/zmbackup --email-only
```

#### Import Süreci

1. **Veri Senkronizasyonu**: Kaynak sunucudan rsync ile veri çekme
2. **Domain Import**: Domainleri import etme
3. **Kullanıcı Import**: Şifrelerle birlikte kullanıcı hesaplarını import etme
4. **İmza Import**: Email imzalarını import etme
5. **Otomatik Yanıt Import**: Mesai dışı mesajlarını import etme
6. **Filtre Import**: Mail filtresi kurallarını import etme
7. **Kişi Import**: Kişileri import etme
8. **Takvim Import**: Takvim etkinliklerini import etme
9. **Dosya Çantası Import**: Dosya çantası dosyalarını import etme
10. **Yönlendirme Import**: Mail yönlendirme kurallarını import etme
11. **Takma Ad Import**: Email takma adlarını import etme
12. **Dağıtım Listesi Import**: Dağıtım listelerini import etme
13. **Email Import**: imapsync ile emailleri import etme (geliştirilmiş özelliklerle)
14. **Tercih Import**: Kullanıcı tercihlerini import etme
15. **Yasal Dinleme Import**: Yasal dinleme ayarlarını import etme
16. **Paylaşım Ayarları Import**: Paylaşılan kaynakları import etme
17. **Kullanıcı Durumu Import**: Kullanıcı hesap durumunu import etme
18. **Import Sonrası Email Re-sync**: Göç sırasında gelen yeni emailleri senkronize etme seçeneği

#### Sadece Email Modu

`--email-only` bayrağı sadece email import adımını çalıştırmanıza izin verir, diğer tüm import işlemlerini atlar. Bu özellik şu durumlarda kullanışlıdır:

- İlk göçten sonra gelen yeni emailleri senkronize etmek
- Tam import süreci olmadan emailleri yeniden senkronize etmek
- Hızlı email senkronizasyonu

```bash
# Sadece email import'u çalıştır
sudo ./import_zimbra.sh <kaynak_sunucu_ip> /opt/zmbackup --email-only
```

#### Geliştirilmiş imapsync Özellikleri

Email import süreci birkaç geliştirme içerir:

- **Paralel İşleme**: Daha hızlı göç için aynı anda 10 email hesabını işler
- **Sessiz Çalışma**: imapsync tamamen sessiz çalışır - işlem sırasında ekrana çıktı basılmaz
- **Ayrı Log Dosyaları**: Her kullanıcının email senkronizasyonu `${BACKUP_DIR}/imapsync_logs/${email}.log` dosyasına loglanır
- **Kullanıcı Doğrulama**: Senkronizasyondan önce kullanıcının hedef sunucuda var olup olmadığını kontrol eder
- **Yeniden Deneme Mekanizması**: Başarısız senkronizasyonları 10 saniye gecikmeyle 3 kez otomatik olarak yeniden dener
- **Timeout Koruması**: Takılan bağlantıları önlemek için 120 saniyelik timeout'lar
- **Hata Tespiti**: Log dosyalarını hata ve uyarılar için analiz eder
- **Şifre Güvenliği**: Admin şifreleri kullanımdan sonra bellekten temizlenir
- **Versiyon Gösterimi**: Başlangıçta imapsync versiyonunu gösterir
- **Başarısız Kullanıcı Raporu**: İşlem sonunda başarısız email import'ları için detaylı rapor (hem ekranda hem log dosyasında)
- **Ctrl+C Desteği**: Ctrl+C'ye basarak tüm imapsync süreçlerini anında durdurabilirsiniz

#### Import Sonrası Email Re-sync

Tüm import adımları tamamlandıktan sonra, script göç sırasında eski sunucuya gelen yeni emailleri yakalamak için tekrar senkronize etmeyi önerir:

```
Not: Göç sırasında eski sunucuya yeni emailler geldiyse,
şimdi tekrar senkronize edebilirsiniz.

Yeni emailleri yakalamak için emailleri tekrar senkronize etmek ister misiniz? (y/n):
```

Bu özellik:
- Sadece emailleri senkronize eder (diğer import adımlarını atlar)
- Devam etme özelliğini kullanır (sadece eksik/yeni emailleri senkronize eder)
- Progress bar ile ilerlemeyi gösterir
- Senkronizasyon süresini ayrı takip eder

#### Import Gereksinimleri

- **Kaynak Sunucu Erişimi**: Kaynak sunucuya root SSH erişimi
- **Ağ Bağlantısı**: Kararlı ağ bağlantısı
- **imapsync**: Kurulu ve yapılandırılmış
- **Admin Şifreleri**: Email göçü için gerekli (güvenli şekilde girilir)

## Devam Etme Özelliği

### Nasıl Çalışır

Script'ler `.export_state` veya `.import_state` dizinlerinde durum dosyaları tutar. Her tamamlanan öğe takip edilir, böylece script kaldığı yerden devam edebilir.

### Export'ta Devam Etme

```bash
# Export kesintiye uğrarsa, sadece tekrar çalıştırın
sudo ./export_zimbra.sh

# Script önceki oturumu algılayacak ve soracak:
# "Previous export session detected!
#  Last progress: Passwords - 415/926
#  Resume from where you left off? (y/n)"
```

### Import'ta Devam Etme

```bash
# Import kesintiye uğrarsa, sadece tekrar çalıştırın
sudo ./import_zimbra.sh <kaynak_sunucu_ip>

# Script önceki oturumu algılayacak ve soracak:
# "Previous import session detected!
#  Last progress: Users - 415/926
#  Resume from where you left off? (y/n)"
```

### Durum Dosyaları

Durum dosyaları şurada saklanır:
- Export: `/opt/zmbackup/.export_state/`
- Import: `/opt/zmbackup/.import_state/`

Her adımın kendi tamamlanma dosyası vardır:
- `passwords_completed.txt` - Tamamlanan şifre export'ları
- `users_completed.txt` - Tamamlanan kullanıcı import'ları
- vb.

### Sıfırdan Başlama

Sıfırdan başlamak için (önceki ilerlemeyi yok say):
```bash
# Devam etme sorusuna 'n' yanıtı verin
# Veya manuel olarak durum dosyalarını silin:
sudo rm -rf /opt/zmbackup/.export_state/*
sudo rm -rf /opt/zmbackup/.import_state/*
```

## İlerleme Takibi

### İlerleme Çubuğu Görüntüsü

Script'ler gerçek zamanlı ilerleme bilgisi gösterir:

```
Passwords [==========>] 45% (415/926) | 00:05:23 | ETA: 00:06:15 | user@domain.com
```

- **İlerleme Çubuğu**: Tamamlanmanın görsel temsili
- **Yüzde**: Mevcut tamamlanma yüzdesi
- **Sayı**: Mevcut öğe / Toplam öğe
- **Geçen Süre**: Başlangıçtan beri geçen süre (SS:DD:SS)
- **Tahmini Kalan Süre**: Tahmini kalan süre (SS:DD:SS)
- **Mevcut Öğe**: Şu anda işlenen öğe (uzunsa kısaltılır)

### Terminal Uyumu

İlerleme çubukları otomatik olarak terminal genişliğine uyum sağlar:
- **Dar terminaller** (<100 karakter): Kompakt görüntü
- **Standart terminaller** (100-120 karakter): Standart görüntü
- **Geniş terminaller** (>120 karakter): Genişletilmiş görüntü

### İlerleme Bilgisi

İlerleme bilgisi şuraya kaydedilir:
- Export: `/opt/zmbackup/.export_state/progress.txt`
- Import: `/opt/zmbackup/.import_state/progress.txt`

Format: `adım_adı|mevcut|toplam|yüzde|zaman_damgası`

## Loglama

### Log Dosyaları

- **Export Log**: `/opt/zmbackup/export.log`
- **Import Log**: `/opt/zmbackup/import.log`

### Log Formatı

```
[2024-01-15 10:30:45] [INFO] Starting export step: passwords
[2024-01-15 10:30:46] [INFO] Total items: 926 | Already exported: 0 | Remaining: 926
[2024-01-15 10:35:12] [INFO] ✓ passwords completed | Processed: 926/926
[2024-01-15 10:35:13] [ERROR] Failed to export: user@domain.com
```

### Log Seviyeleri

- **INFO**: Genel bilgi mesajları
- **ERROR**: Hata mesajları ve başarısızlıklar
- **WARNING**: Uyarı mesajları (şu anda kullanılmıyor)

### Log Görüntüleme

```bash
# Export log'unu görüntüle
tail -f /opt/zmbackup/export.log

# Import log'unu görüntüle
tail -f /opt/zmbackup/import.log

# Hataları ara
grep ERROR /opt/zmbackup/export.log

# Son 100 satırı görüntüle
tail -n 100 /opt/zmbackup/export.log
```

## Sorun Giderme

### Yaygın Sorunlar

#### 1. İzin Hatası

**Hata**: `Permission denied` veya `Cannot access`

**Çözüm**:
```bash
# Script'in çalıştırılabilir olduğundan emin olun
chmod +x export_zimbra.sh import_zimbra.sh

# Root olarak çalıştırdığınızdan emin olun
sudo ./export_zimbra.sh

# Zimbra kullanıcı izinlerini kontrol edin
sudo -u zimbra /opt/zimbra/bin/zmprov -l gaa
```

#### 2. Durum Dizini Sorunları

**Hata**: Durum dosyaları oluşturulmuyor

**Çözüm**:
```bash
# Durum dizinini manuel oluşturun
sudo mkdir -p /opt/zmbackup/.export_state
sudo mkdir -p /opt/zmbackup/.import_state
sudo chown -R zimbra:zimbra /opt/zmbackup
```

#### 3. İlerleme Çubuğu Görüntülenmiyor

**Hata**: İlerleme çubuğu escape kodları gösteriyor veya güncellenmiyor

**Çözüm**:
- Terminal'in ANSI renklerini desteklediğinden emin olun
- Terminal genişliğini kontrol edin: `tput cols`
- Modern bir terminal emülatörü kullanın

#### 4. Devam Etme Çalışmıyor

**Hata**: Script önceki oturumu algılamıyor

**Çözüm**:
```bash
# Durum dosyalarının var olduğunu kontrol edin
ls -la /opt/zmbackup/.export_state/

# İlerleme dosyasını kontrol edin
cat /opt/zmbackup/.export_state/progress.txt

# Dosya izinlerini doğrulayın
sudo chown -R zimbra:zimbra /opt/zmbackup/.export_state
```

#### 5. imapsync Bulunamadı

**Hata**: `imapsync does not exist`

**Çözüm**:
```bash
# imapsync'i yükleyin
# RHEL/CentOS'ta:
sudo yum install imapsync

# Ubuntu/Debian'da:
sudo apt-get install imapsync

# Kurulumu doğrulayın
which imapsync

# Versiyonu kontrol edin
imapsync --version
```

#### 5a. imapsync Log Dosyaları

**Konum**: Her kullanıcı için ayrı log dosyaları `${BACKUP_DIR}/imapsync_logs/` dizininde oluşturulur

**Log görüntüleme**:
```bash
# Belirli bir kullanıcı için log görüntüle
cat /opt/zmbackup/imapsync_logs/user@domain.com.log

# Tüm loglarda hata ara
grep -r "ERROR\|FATAL" /opt/zmbackup/imapsync_logs/

# Log'un son 50 satırını görüntüle
tail -n 50 /opt/zmbackup/imapsync_logs/user@domain.com.log
```

#### 5b. Sadece Email Modu

**Kullanım**: Diğer import adımları olmadan sadece email import'u çalıştır

```bash
# Sadece emailleri senkronize et
sudo ./import_zimbra.sh <kaynak_sunucu_ip> /opt/zmbackup --email-only
```

**Kullanım durumları**:
- İlk göçten sonra gelen yeni emailleri senkronize etmek
- Tam import olmadan emailleri yeniden senkronize etmek
- Hızlı email senkronizasyonu

#### 6. rsync Bağlantı Sorunları

**Hata**: `rsync: connection refused` veya `Permission denied`

**Çözüm**:
```bash
# SSH bağlantısını test edin
ssh root@kaynak_sunucu_ip

# rsync'i manuel test edin
rsync -azlgop root@kaynak_sunucu_ip:/opt/zmbackup/ /tmp/test/

# SSH anahtarlarının kurulu olduğundan emin olun (isteğe bağlı ama önerilir)
ssh-copy-id root@kaynak_sunucu_ip
```

#### 7. Zimbra Komut Hataları

**Hata**: `zmprov: command not found` veya `zmmailbox: command not found`

**Çözüm**:
```bash
# Zimbra kurulumunu doğrulayın
sudo -u zimbra /opt/zimbra/bin/zmprov --version

# Zimbra kullanıcısını kontrol edin
id zimbra

# Root olarak çalıştırdığınızdan emin olun
sudo ./export_zimbra.sh
```

### Performans İpuçları

1. **screen veya tmux kullanın**: Bağlantı kesilme sorunlarını önler
   ```bash
   screen -S zimbra_migration
   sudo ./export_zimbra.sh
   # Ctrl+A sonra D'ye basarak ayırın
   ```

2. **Disk alanını izleyin**: Yeterli alan olduğundan emin olun
   ```bash
   df -h /opt/zmbackup
   ```

3. **Ağ optimizasyonu**: Büyük göçler için kararlı ağ sağlayın
   ```bash
   # Ağ hızını test edin
   iperf3 -c kaynak_sunucu_ip
   ```

4. **Kaynak izleme**: Sistem kaynaklarını izleyin
   ```bash
   # CPU ve bellek izleme
   top
   # Veya
   htop
   ```

### En İyi Uygulamalar

1. **Önce Test Edin**: Tek bir domain veya küçük kullanıcı grubu ile test edin
2. **Önce Yedekleyin**: Göçten önce her zaman yedek alın
3. **Screen Kullanın**: Uzun süren işlemler için screen veya tmux kullanın
4. **Logları İzleyin**: Göç sırasında log dosyalarını izleyin
5. **Veriyi Doğrulayın**: Import'tan önce export edilen veriyi doğrulayın
6. **Aşamalı Göç**: Aşamalı göç düşünün (domainler, kullanıcılar, emailler)

---

## 📝 License / Lisans

These scripts are provided as-is for Zimbra migration purposes. Use at your own risk.

Bu script'ler Zimbra göçü amaçlı olduğu gibi sağlanmıştır. Kendi riskinizle kullanın.

---

## 🤝 Contributing / Katkıda Bulunma

Contributions, issues, and feature requests are welcome!

Katkılar, sorunlar ve özellik istekleri memnuniyetle karşılanır!

---

## 📧 Support / Destek

For issues or questions, please check the logs first:
- Export log: `/opt/zmbackup/export.log`
- Import log: `/opt/zmbackup/import.log`

Sorunlar veya sorular için lütfen önce logları kontrol edin:
- Export log: `/opt/zmbackup/export.log`
- Import log: `/opt/zmbackup/import.log`

---

#### Parallel Email Import

Email import now runs in parallel mode by default:
- **10 concurrent jobs**: Up to 10 email accounts are processed simultaneously
- **Automatic job management**: New jobs start automatically as others complete
- **Progress tracking**: Progress bar shows overall progress across all parallel jobs
- **Resource efficient**: Manages system resources while maximizing throughput

#### Silent imapsync Operation

During email import:
- **No screen output**: imapsync runs completely silently - no logs or messages on screen
- **Progress bar only**: Only the progress bar is shown during processing
- **Detailed logs**: All details are saved to individual log files in `${BACKUP_DIR}/imapsync_logs/`
- **Error reporting**: Failed imports are reported in detail at the end

#### Failed User Report

After email import completes, if there are any failures:
- **On-screen report**: Detailed report displayed on screen with error messages
- **Log file report**: Same report saved to log file for later review
- **Error details**: Shows first 3-5 error lines from each user's log file
- **Log file paths**: Provides path to each user's detailed log file

Example report:
```
════════════════════════════════════════════════════════════
Failed Email Import Report
════════════════════════════════════════════════════════════

✗ user1@domain.com
    ERROR: Authentication failed
    FATAL: Connection timeout

✗ user2@domain.com
    ERROR: Login failed
    Check log file: /opt/zmbackup/imapsync_logs/user2@domain.com.log

════════════════════════════════════════════════════════════
```

#### Ctrl+C Support

During email import, you can press Ctrl+C to stop:
- **Immediate stop**: All running imapsync processes are stopped immediately
- **Graceful shutdown**: First attempts graceful shutdown (TERM signal)
- **Force kill**: If needed, force kills remaining processes (KILL signal)
- **Clean exit**: Cleans up temporary files and exits cleanly

**Note**: Press Ctrl+C once and wait - the script will handle cleanup automatically.

---

#### Paralel Email Import

Email import artık varsayılan olarak paralel modda çalışır:
- **10 eşzamanlı iş**: Aynı anda 10 email hesabı işlenir
- **Otomatik iş yönetimi**: Diğerleri tamamlandıkça yeni işler otomatik başlar
- **İlerleme takibi**: Progress bar tüm paralel işlerdeki genel ilerlemeyi gösterir
- **Kaynak verimli**: Maksimum verimi sağlarken sistem kaynaklarını yönetir

#### Sessiz imapsync İşlemi

Email import sırasında:
- **Ekrana çıktı yok**: imapsync tamamen sessiz çalışır - ekrana log veya mesaj basılmaz
- **Sadece progress bar**: İşlem sırasında sadece progress bar gösterilir
- **Detaylı loglar**: Tüm detaylar `${BACKUP_DIR}/imapsync_logs/` dizinindeki ayrı log dosyalarına kaydedilir
- **Hata raporlama**: Başarısız import'lar sonunda detaylı raporlanır

#### Başarısız Kullanıcı Raporu

Email import tamamlandıktan sonra, başarısızlık varsa:
- **Ekranda rapor**: Hata mesajlarıyla birlikte ekranda detaylı rapor gösterilir
- **Log dosyası raporu**: Aynı rapor log dosyasına kaydedilir (daha sonra inceleme için)
- **Hata detayları**: Her kullanıcının log dosyasından ilk 3-5 hata satırını gösterir
- **Log dosyası yolları**: Her kullanıcının detaylı log dosyasının yolunu sağlar

Örnek rapor:
```
════════════════════════════════════════════════════════════
Failed Email Import Report
════════════════════════════════════════════════════════════

✗ user1@domain.com
    ERROR: Authentication failed
    FATAL: Connection timeout

✗ user2@domain.com
    ERROR: Login failed
    Check log file: /opt/zmbackup/imapsync_logs/user2@domain.com.log

════════════════════════════════════════════════════════════
```

#### Ctrl+C Desteği

Email import sırasında Ctrl+C'ye basarak durdurabilirsiniz:
- **Anında durdurma**: Tüm çalışan imapsync süreçleri anında durdurulur
- **Zarif kapanış**: Önce zarif kapanış denenir (TERM sinyali)
- **Zorla öldürme**: Gerekirse kalan süreçler zorla öldürülür (KILL sinyali)
- **Temiz çıkış**: Geçici dosyaları temizler ve temiz bir şekilde çıkar

**Not**: Ctrl+C'ye bir kez basın ve bekleyin - script temizliği otomatik yapacaktır.

---

**Last Updated / Son Güncelleme**: 2025-01-20

