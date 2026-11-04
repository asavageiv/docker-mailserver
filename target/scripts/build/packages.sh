#!/bin/bash

# -e          :: exit on error (do this in functions as well)
# -E          :: inherit the ERR trap to functions, command substitutions and sub-shells
# -u          :: show (and exit) when using unset variables
# -o pipefail :: exit on error in pipes
set -eE -u -o pipefail

# shellcheck source=../helpers/log.sh
source /usr/local/bin/helpers/log.sh

_log_level_is 'trace' && QUIET='-y' || QUIET='-qq'

function _pre_installation_steps() {
  _log 'info' 'Starting package installation'
  _log 'debug' 'Running pre-installation steps'

  _log 'trace' 'Refreshing local package index'
  apt-get "${QUIET}" update

  _log 'trace' 'Upgrading packages'
  apt-get "${QUIET}" upgrade

  _log 'trace' 'Installing packages that are needed early'
  local EARLY_PACKAGES=(
    # Avoid logging unnecessary warnings:
    apt-utils
    # Required to ensure correct `clamav` ownership (for associated COPY in Dockerfile):
    adduser
    # Required to download third-party software (see `_install_utils`):
    ca-certificates curl
    # Avoid problems with SA / Amavis (https://github.com/docker-mailserver/docker-mailserver/pull/3403#pullrequestreview-1596689953):
    systemd-standalone-sysusers
  )

  apt-get "${QUIET}" install --no-install-recommends "${EARLY_PACKAGES[@]}" 2>/dev/null

  # Ensure ownership is assigned to the `clamav` user/group (sync to the UID 200 ownership from the COPY instruction in the Dockerfile):
  # When the `clamav` package is later installed it will use this UID instead (otherwise value assigned would vary when modifying the package list).
  # https://github.com/docker-mailserver/docker-mailserver/issues/2942#issuecomment-1383512079
  adduser --quiet --system --group --disabled-password --home /var/lib/clamav --no-create-home --uid 200 clamav
}

# Install third-party commands to /usr/local/bin
function _install_utils() {
  local ARCH_A
  ARCH_A=$(uname --machine)
  # Alternate naming convention support: x86_64 (amd64) / aarch64 (arm64)
  # https://en.wikipedia.org/wiki/X86-64#Industry_naming_conventions
  local ARCH_B
  case "${ARCH_A}" in
    ( 'x86_64'  ) ARCH_B='amd64' ;;
    ( 'aarch64' ) ARCH_B='arm64' ;;
    ( * )
      _log 'error' "Unsupported arch: '${ARCH_A}'"
      return 1
      ;;
  esac

  _log 'debug' 'Installing utilities from Github'

  _log 'trace' 'Installing step'
  local STEP_CLI_VERSION='0.30.6'
  curl -sSfL -o /tmp/step-cli.deb \
    "https://github.com/smallstep/cli/releases/download/v${STEP_CLI_VERSION}/step-cli_${ARCH_B}.deb"
  dpkg -i /tmp/step-cli.deb
  rm /tmp/step-cli.deb
}

function _install_packages() {
  _log 'debug' 'Installing all packages now'

  local ANTI_VIRUS_SPAM_PACKAGES=(
    clamav clamav-daemon
    # spamassassin is used only with amavisd-new
    amavisd-new spamassassin
  )

  # predominantly for Amavis support
  local CODECS_PACKAGES=(
    altermime arj bzip2
    cabextract cpio file
    gzip lhasa lz4
    lrzip lzop nomarch
    p7zip-full pax rpm2cpio
    unrar-free unzip xz-utils
  )

  local MISCELLANEOUS_PACKAGES=(
    binutils bsd-mailx
    dbconfig-no-thanks dumb-init iproute2
    libdate-manip-perl libldap-common libmail-spf-perl libnet-dns-perl
    locales logwatch netcat-openbsd
    nftables # primarily for Fail2Ban
    jaq # used to parse JSON (the update check)
    perl-doc # required for `swaks --help` to work
    rsyslog supervisor swaks
    uuid # used for file-locking
    whois
  )

  local POSTFIX_PACKAGES=(
    pflogsumm postgrey postfix postfix-ldap postfix-mta-sts-resolver
    postfix-pcre postfix-policyd-spf-python postsrsd
  )

  local MAIL_PROGRAMS_PACKAGES=(
    opendkim opendkim-tools
    opendmarc libsasl2-modules sasl2-bin
  )

  # These packages support community contributed features.
  # If they cause too much maintenance burden in future, they are liable for removal.
  local COMMUNITY_PACKAGES=(
    fetchmail getmail6
  )

  # `bind9-dnsutils` provides the `dig` command
  # `iputils-ping` provides the `ping` command
  DEBUG_PACKAGES=(
    bind9-dnsutils iputils-ping less nano
  )

  apt-get "${QUIET}" install --no-install-recommends \
    "${ANTI_VIRUS_SPAM_PACKAGES[@]}" \
    "${CODECS_PACKAGES[@]}" \
    "${MISCELLANEOUS_PACKAGES[@]}" \
    "${POSTFIX_PACKAGES[@]}" \
    "${MAIL_PROGRAMS_PACKAGES[@]}" \
    "${DEBUG_PACKAGES[@]}" \
    "${COMMUNITY_PACKAGES[@]}"
}

function _install_dovecot() {
  local DOVECOT_PACKAGES=(
    dovecot-core
    dovecot-lmtpd
    dovecot-imapd
    dovecot-pop3d
    dovecot-sieve
    dovecot-managesieved
    dovecot-ldap
    dovecot-flatcurve

    # Additional Dovecot packages for supporting the DMS community (docs-only guide contributions)
    dovecot-auth-lua
    dovecot-solr
  )

  _log 'debug' 'Installing Dovecot'
  apt-get "${QUIET}" install --no-install-recommends "${DOVECOT_PACKAGES[@]}"

  # We remove the enabled-by-default Flatcurve configuration to disable FTS by default
  rm /etc/dovecot/conf.d/90-fts-flatcurve.conf
}

function _install_rspamd() {
  _log 'debug' 'Installing Rspamd'
  apt-get "${QUIET}" install rspamd valkey-server
}

function _install_fail2ban() {
  _log 'debug' 'Installing Fail2ban'
  # Dependencies (https://github.com/docker-mailserver/docker-mailserver/pull/3403#discussion_r1306581431):
  apt-get "${QUIET}" install --no-install-recommends fail2ban python3-pyinotify python3-dnspython python3-systemd

  # The Debian package enables an `sshd` jail (systemd backend) and sets default ban actions.
  # DMS runs no sshd and has no journal, and configures its own jails and ban action in `jail.local`:
  rm /etc/fail2ban/jail.d/defaults-debian.conf
}

function _post_installation_steps() {
  _log 'debug' 'Running post-installation steps (cleanup)'
  _log 'debug' 'Deleting sensitive files (secrets)'
  rm /etc/postsrsd.secret

  _log 'debug' 'Deleting default logwatch cronjob'
  rm /etc/cron.daily/00logwatch

  _log 'trace' 'Removing leftovers from APT'
  apt-get "${QUIET}" clean
  rm -rf /var/lib/apt/lists/*

  # Irrelevant config for DMS:
  # Creating a separate syslog socket was necessary as Debian configured
  # Postfix to run via chroot jail (DMS avoids that intentionally).
  rm /etc/rsyslog.d/postfix.conf
}

_pre_installation_steps
_install_utils
_install_packages
_install_dovecot
_install_rspamd
_install_fail2ban
_post_installation_steps
