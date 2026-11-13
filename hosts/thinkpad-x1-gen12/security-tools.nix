# Security / web-audit tooling for 0xff on the thinkpad, grouped the way the
# audit workspaces are laid out (subdomains / dns / ports / ssl / web). These
# are the standard open-source recon and scanning CLIs, same ones Kali ships;
# nixpkgs builds them from source, so no Kali repo or FHS layer is involved.
# Kept in their own module so the host's package list stays readable, and so
# the whole set can be dropped by removing one import.
{ pkgs, ... }:
{
  home-manager.users."0xff".home.packages = with pkgs; [
    # Subdomain / asset discovery
    subfinder
    amass
    dnsx
    gau
    waybackurls
    hakrawler

    # DNS / whois
    dnsutils # dig, nslookup, host
    ldns # drill
    whois

    # Port / service scanning
    nmap
    naabu
    rustscan
    masscan

    # TLS / SSL
    sslscan
    testssl
    tlsx

    # Web content discovery & fuzzing
    httpx # projectdiscovery http probe
    katana # crawler
    ffuf
    feroxbuster
    gobuster
    dirb

    # Web app scanning
    nikto
    whatweb
    wafw00f
    wpscan
    nuclei
    nuclei-templates
    arjun # parameter discovery
    dalfox # XSS
    sqlmap

    # Secret scanning (useful on cloned targets)
    gitleaks
    trufflehog

    # Wordlists the fuzzers point at
    seclists
    wordlists
  ];
}
