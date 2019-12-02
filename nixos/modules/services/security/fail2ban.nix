{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.services.fail2ban;

  fail2banConf = pkgs.writeText "fail2ban.local" cfg.daemonConfig;

  jailConf = pkgs.writeText "jail.local" ''
    [INCLUDES]

    before = paths-nixos.conf

    ${concatStringsSep "\n" (attrValues (flip mapAttrs cfg.jails (name: def:
      optionalString (def != "")
        ''
          [${name}]
          ${def}
        '')))}
  '';

  pathsConf = pkgs.writeText "paths-nixos.conf" ''
    # NixOS

    [INCLUDES]

    before = paths-common.conf

    after  = paths-overrides.local

    [DEFAULT]
  '';

in

{

  ###### interface

  options = {

    services.fail2ban = {
      enable = mkOption {
        default = false;
        type = types.bool;
        description = "Whether to enable the fail2ban service.";
      };

      package = mkOption {
        default = pkgs.fail2ban;
        type = types.package;
        example = "pkgs.fail2ban_0_11";
        description = "The fail2ban package to use for running the fail2ban service.";
      };

      packageFirewall = mkOption {
        default = pkgs.iptables;
        type = types.package;
        example = "pkgs.nftables";
        description = "The firewall package used by fail2ban service.";
      };

      daemonConfig = mkOption {
        default = ''
          [Definition]
          logtarget = SYSLOG
          socket    = /run/fail2ban/fail2ban.sock
          pidfile   = /run/fail2ban/fail2ban.pid
          dbfile    = /var/lib/fail2ban/fail2ban.sqlite3
        '';
        type = types.lines;
        description = ''
          The contents of Fail2ban's main configuration file.  It's
          generally not necessary to change it.
       '';
      };

      jails = mkOption {
        default = { };
        example = literalExample ''
          { apache-nohome-iptables = '''
              # Block an IP address if it accesses a non-existent
              # home directory more than 5 times in 10 minutes,
              # since that indicates that it's scanning.
              filter   = apache-nohome
              action   = iptables-multiport[name=HTTP, port="http,https"]
              logpath  = /var/log/httpd/error_log*
              findtime = 600
              bantime  = 600
              maxretry = 5
            ''';
          }
        '';
        type = types.attrsOf types.lines;
        description = ''
          The configuration of each Fail2ban “jail”.  A jail
          consists of an action (such as blocking a port using
          <command>iptables</command>) that is triggered when a
          filter applied to a log file triggers more than a certain
          number of times in a certain time period.  Actions are
          defined in <filename>/etc/fail2ban/action.d</filename>,
          while filters are defined in
          <filename>/etc/fail2ban/filter.d</filename>.
        '';
      };

    };

  };

  ###### implementation

  config = mkIf cfg.enable {

    environment.systemPackages = [ cfg.package ];

    environment.etc = {
      "fail2ban/fail2ban.local".source = fail2banConf;
      "fail2ban/jail.local".source = jailConf;
      "fail2ban/fail2ban.conf".source = "${cfg.package}/etc/fail2ban/fail2ban.conf";
      "fail2ban/jail.conf".source = "${cfg.package}/etc/fail2ban/jail.conf";
      "fail2ban/paths-common.conf".source = "${cfg.package}/etc/fail2ban/paths-common.conf";
      "fail2ban/paths-nixos.conf".source = pathsConf;
      "fail2ban/action.d".source = "${cfg.package}/etc/fail2ban/action.d/*.conf";
      "fail2ban/filter.d".source = "${cfg.package}/etc/fail2ban/filter.d/*.conf";
    };

    systemd.services.fail2ban = {
      description = "Fail2ban Intrusion Prevention System";

      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      partOf = optional config.networking.firewall.enable "firewall.service";

      restartTriggers = [ fail2banConf jailConf pathsConf ];
      reloadIfChanged = true;

      path = [ cfg.package cfg.packageFirewall pkgs.iproute ];

      unitConfig.Documentation = "man:fail2ban(1)";

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/fail2ban-server -xf start";
        ExecStop = "${cfg.package}/bin/fail2ban-server stop";
        ExecReload = "${cfg.package}/bin/fail2ban-server reload";
        Type = "simple";
        Restart = "on-failure";
        PIDFile = "/run/fail2ban/fail2ban.pid";

        ReadOnlyDirectories = "/";
        ReadWriteDirectories = "/run/fail2ban /var/tmp /var/lib";
        PrivateTmp = "true";
        RuntimeDirectory = "fail2ban";
        CapabilityBoundingSet = "CAP_DAC_READ_SEARCH CAP_NET_ADMIN CAP_NET_RAW";
      };
    };

    # Add some reasonable default jails.  The special "DEFAULT" jail
    # sets default values for all other jails.
    services.fail2ban.jails.DEFAULT = ''
      # Miscellaneous options
      ignoreip    = 127.0.0.1/8 ${optionalString config.networking.enableIPv6 "::1"}
      maxretry    = 3
      backend     = systemd
    '';
    # Block SSH if there are too many failing connection attempts.
    services.fail2ban.jails.sshd = mkDefault ''
      enabled = true
      port    = ${concatMapStringsSep "," (p: toString p) config.services.openssh.ports}
    '';
  };
}
