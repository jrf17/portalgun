#!/usr/bin/env python3
"""
Fetch READMEs for static tools defined in tools_readme.html toolsData array.

Strategy:
1. Use a curated known-good mapping for common tools (most reliable)
2. Fall back to GitHub Search API for unknown ones (rate limited to 60/hr unauth)
3. Cache all fetched READMEs in /var/cache/portalgun/static-readmes/<safe_name>.md
4. Emit a manifest mapping tool name -> {readme_path, repo_url}

Run: sudo python3 fetch_static_readmes.py
"""
import json
import os
import re
import sys
import time
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path

CACHE_DIR = Path(os.environ.get("PG_STATIC_CACHE", "/var/cache/portalgun/static-readmes"))
MAPPING_FILE = Path(os.environ.get("PG_STATIC_MAP", "/var/cache/portalgun/static-tools-map.json"))
STATIC_TOOLS = Path(os.environ.get("PG_STATIC_TOOLS", "/tmp/static_tools.json"))

# Curated mapping: tool name → owner/repo
# Adding the most common tools that show up in the UI
KNOWN_REPOS = {
    # Sharp* C# tools
    "Rubeus": "GhostPack/Rubeus",
    "Certify": "GhostPack/Certify",
    "Certipy": "ly4k/Certipy",
    "SharpHound": "BloodHoundAD/SharpHound",
    "SharpHound-DOC": "BloodHoundAD/SharpHound",
    "BloodHound.py": "dirkjanm/BloodHound.py",
    "BloodHound": "BloodHoundAD/BloodHound",
    "SharpSCCM": "Mayyhem/SharpSCCM",
    "SharpGPOAbuse": "FSecureLABS/SharpGPOAbuse",
    "SharpView": "tevora-threat/SharpView",
    "SharpMad": "bohops/SharpMad",
    "SharpMove": "0xthirteen/SharpMove",
    "SharpRDP": "0xthirteen/SharpRDP",
    "SharpSuccessor": "logangoins/SharpSuccessor",
    "SharpEfsPotato": "bugch3ck/SharpEfsPotato",
    "SharpUp": "GhostPack/SharpUp",
    "SharpKatz": "b4rtik/SharpKatz",
    "SharpDPAPI": "GhostPack/SharpDPAPI",
    "SharpChrome": "GhostPack/SharpDPAPI",
    "SharpLAPS": "swisskyrepo/SharpLAPS",
    "SharpWMI": "GhostPack/SharpWMI",
    "SharpZeroLogon": "Flangvik/SharpZeroLogon",
    "Seatbelt": "GhostPack/Seatbelt",
    "SharpRoast": "GhostPack/SharpRoast",
    "SharpDump": "GhostPack/SharpDump",
    "SharpEDRChecker": "PwnDexter/SharpEDRChecker",
    "SharpCollection": "Flangvik/SharpCollection",
    "SharpGPO-RemoteAccessPolicies": "FSecureLABS/SharpGPO-RemoteAccessPolicies",
    "SCCMHunter": "garrettfoster13/sccmhunter",
    "SCCMSecrets.py": "synacktiv/SCCMSecrets",
    "ADExplorerSnapshot.py": "c3c/ADExplorerSnapshot.py",
    # Active Directory
    "PowerView": "PowerShellMafia/PowerSploit",
    "PowerSploit": "PowerShellMafia/PowerSploit",
    "ADModule": "samratashok/ADModule",
    "ADRecon": "adrecon/ADRecon",
    "adPEAS": "Cerbersec/adPEAS",
    "BadBlood": "davidprowe/BadBlood",
    "Snaffler": "SnaffCon/Snaffler",
    "ldapdomaindump": "dirkjanm/ldapdomaindump",
    "ldapsearch-ad": "yaap7/ldapsearch-ad",
    "ldeep": "franc-pentest/ldeep",
    "bloodyAD": "CravateRouge/bloodyAD",
    "godap": "Macmod/godap",
    "NetExec": "Pennyw0rth/NetExec",
    "CrackMapExec": "byt3bl33d3r/CrackMapExec",
    "impacket": "fortra/impacket",
    "Impacket-scripts": "fortra/impacket",
    "kerbrute": "ropnop/kerbrute",
    "Kerbrute-py": "TarlogicSecurity/kerbrute",
    "MailSniper": "dafthack/MailSniper",
    "MSSqlPwner": "ScorpionesLabs/MSSqlPwner",
    "PetitPotam": "topotam/PetitPotam",
    "Coercer": "p0dalirius/Coercer",
    "krbrelayx": "dirkjanm/krbrelayx",
    "krbrelay": "cube0x0/KrbRelay",
    "Responder": "lgandx/Responder",
    "ntlmrelayx": "fortra/impacket",
    "rusthound": "OPENCYBER-FR/RustHound",
    "RustHound-CE": "g0h4n/RustHound-CE",
    # Kerberos
    "Rubeus-py": "stigward/rubeus-py",
    "Kerberoast": "nidem/kerberoast",
    "noPac": "Ridter/noPac",
    "nopac.py": "Ridter/noPac",
    "PKINITtools": "dirkjanm/PKINITtools",
    "BadSuccessor": "akamai/BadSuccessor",
    "TargetedKerberoast": "ShutdownRepo/targetedKerberoast",
    "Tickey": "TarlogicSecurity/tickey",
    # Credentials
    "mimikatz": "gentilkiwi/mimikatz",
    "lazagne": "AlessandroZ/LaZagne",
    "donpapi": "login-securite/DonPAPI",
    "DPAPI-Probe": "RICHRMM/DPAPI_Probe",
    "Lsassy": "Hackndo/lsassy",
    "Pypykatz": "skelsec/pypykatz",
    "DSInternals": "MichaelGrafnetter/DSInternals",
    # Privilege escalation
    "PEASS-ng": "carlospolop/PEASS-ng",
    "WinPEAS": "carlospolop/PEASS-ng",
    "LinPEAS": "carlospolop/PEASS-ng",
    "GodPotato": "BeichenDream/GodPotato",
    "SigmaPotato": "tylerdotrar/SigmaPotato",
    "SweetPotato": "uknowsec/SweetPotato",
    "JuicyPotato": "ohpe/juicy-potato",
    "JuicyPotatoNG": "antonioCoco/JuicyPotatoNG",
    "RoguePotato": "antonioCoco/RoguePotato",
    "PrintSpoofer": "itm4n/PrintSpoofer",
    "EfsPotato": "zcgonvh/EfsPotato",
    "PrivescCheck": "itm4n/PrivescCheck",
    "linux-smart-enumeration": "diego-treitos/linux-smart-enumeration",
    "linux-exploit-suggester": "The-Z-Labs/linux-exploit-suggester",
    "linux-exploit-suggester-2": "jondonas/linux-exploit-suggester-2",
    "GTFOBins": "GTFOBins/GTFOBins.github.io",
    "gtfonow": "Frissi0n/GTFONow",
    "LOLBAS": "LOLBAS-Project/LOLBAS",
    "pspy": "DominicBreuker/pspy",
    "sudo_killer": "TH3xACE/SUDO_KILLER",
    # Evasion
    "Inveigh": "Kevin-Robertson/Inveigh",
    "AMSI-Bypass": "S3cur3Th1sSh1t/Amsi-Bypass-Powershell",
    "AMSITrigger": "RythmStick/AMSITrigger",
    "Invoke-Obfuscation": "danielbohannon/Invoke-Obfuscation",
    "Defendnot": "thiagoperes/defendnot",
    "BOAZ_beta": "thomasxm/BOAZ_beta",
    "Supernova": "nickvourd/Supernova",
    "Loki": "Neo23x0/Loki",
    "killshot": "p3ta00/killshot",
    "bypassav": "matro7sh/BypassAV",
    "OffensiveVBA": "S3cur3Th1sSh1t/OffensiveVBA",
    "Veil": "Veil-Framework/Veil",
    # Web / Recon
    "ffuf": "ffuf/ffuf",
    "gobuster": "OJ/gobuster",
    "feroxbuster": "epi052/feroxbuster",
    "dirsearch": "maurosoria/dirsearch",
    "nuclei": "projectdiscovery/nuclei",
    "nuclei-templates": "projectdiscovery/nuclei-templates",
    "katana": "projectdiscovery/katana",
    "naabu": "projectdiscovery/naabu",
    "subfinder": "projectdiscovery/subfinder",
    "dnsx": "projectdiscovery/dnsx",
    "httpx": "projectdiscovery/httpx",
    "asnmap": "projectdiscovery/asnmap",
    "amass": "owasp-amass/amass",
    "assetfinder": "tomnomnom/assetfinder",
    "gau": "lc/gau",
    "waybackurls": "tomnomnom/waybackurls",
    "hakrawler": "hakluke/hakrawler",
    "paramspider": "devanshbatham/ParamSpider",
    "Arjun": "s0md3v/Arjun",
    "SSRFmap": "swisskyrepo/SSRFmap",
    "jwt_tool": "ticarpi/jwt_tool",
    "fenjing": "Marven11/Fenjing",
    "crypto-attacks": "jvdsn/crypto-attacks",
    "PayloadsAllTheThings": "swisskyrepo/PayloadsAllTheThings",
    "GitTools": "internetwache/GitTools",
    "reconftw": "six2dez/reconftw",
    "TrevorSpray": "blacklanternsecurity/TREVORspray",
    # Cloud
    "ROADtools": "dirkjanm/ROADtools",
    "AzureHound": "BloodHoundAD/AzureHound",
    "Maestro": "Mayyhem/Maestro",
    "TokenTactics": "rvrsh3ll/TokenTactics",
    "TokenTacticsV2": "f-bader/TokenTacticsV2",
    "MicroBurst": "NetSPI/MicroBurst",
    "powerzure": "hausec/PowerZure",
    "AADInternals": "Gerenios/AADInternals",
    "ScubaGear": "cisagov/ScubaGear",
    "GraphRunner": "dafthack/GraphRunner",
    "MFASweep": "dafthack/MFASweep",
    "MSOLSpray": "dafthack/MSOLSpray",
    "GoMapEnum": "nodauf/GoMapEnum",
    "o365enum": "gremwell/o365enum",
    "o365recon": "nyxgeek/o365recon",
    "o365-attack-toolkit": "mdsecactivebreach/o365-attack-toolkit",
    "TeamFiltration": "Flangvik/TeamFiltration",
    "stormspotter": "Azure/Stormspotter",
    "AWS-consoler": "NetSPI/aws_consoler",
    "awspx": "FSecureLABS/awspx",
    "cloud_enum": "initstring/cloud_enum",
    "cloudbrute": "0xsha/CloudBrute",
    "Cartography": "lyft/cartography",
    "CloudFox": "BishopFox/cloudfox",
    "CloudMapper": "duo-labs/cloudmapper",
    "Cloudsplaining": "salesforce/cloudsplaining",
    "Pacu": "RhinoSecurityLabs/pacu",
    "Prowler": "prowler-cloud/prowler",
    "ScoutSuite": "nccgroup/ScoutSuite",
    "S3Scanner": "sa7mon/S3Scanner",
    "CloudPEASS": "carlospolop/CloudPEASS",
    "WeirdAAL": "carnal0wnage/weirdAAL",
    "EnumerateIAM": "andresriancho/enumerate-iam",
    # C2
    "Sliver": "BishopFox/sliver",
    "Havoc": "HavocFramework/Havoc",
    "Villain": "t3l3machus/Villain",
    "Mythic": "its-a-feature/Mythic",
    "PoshC2": "nettitude/PoshC2",
    "Empire": "EmpireProject/Empire",
    "Covenant": "cobbr/Covenant",
    "metasploit-framework": "rapid7/metasploit-framework",
    # Tunneling / Pivoting
    "ligolo-ng": "nicocha30/ligolo-ng",
    "chisel": "jpillora/chisel",
    "gost": "ginuerzh/gost",
    "ngrok": "inconshreveable/ngrok",
    "frp": "fatedier/frp",
    "rsockstun": "mis-team/rsockstun",
    "Penelope": "brightio/penelope",
    "ssh-snake": "MegaManSec/SSH-Snake",
    # Containers
    "kdigger": "quarkslab/kdigger",
    "cdk": "cdk-team/CDK",
    "peirates": "inguardians/peirates",
    "kubeaudit": "Shopify/kubeaudit",
    "kubeletctl": "cyberark/kubeletctl",
    "trivy": "aquasecurity/trivy",
    # Misc / Util
    "evilginx2": "kgretzky/evilginx2",
    "gophish": "gophish/gophish",
    "EvilProxy": "PylotLight/EvilProxy",
    "AutoFunkt": "dirkjanm/AutoFunkt",
    "darkflare": "doxx/darkflare",
    "evil-winrm-py": "adityatelange/evil-winrm-py",
    "evil-winrm": "Hackplayers/evil-winrm",
    "winrmexec": "ozelis/winrmexec",
    "PEAS-ng": "carlospolop/PEASS-ng",
    "FindGPPPasswords": "p0dalirius/FindGPPPasswords",
    "powermad": "Kevin-Robertson/Powermad",
    "krbrelayup": "Dec0ne/KrbRelayUp",
    "Coercer-py": "p0dalirius/Coercer",
    "remotemonologue": "xforcered/RemoteMonologue",
    "RemotePotato0": "antonioCoco/RemotePotato0",
    "Masky": "Z4kSec/Masky",
    "dploot": "zblurx/dploot",
    "Pre2k": "garrettfoster13/pre2k",
    "RunasCs": "antonioCoco/RunasCs",
    "AdidnsDump": "dirkjanm/adidnsdump",
    "godap-py": "Macmod/godap",
    "ldaprelayscan": "zyn3rgy/LdapRelayScan",
    "PoshADCS": "cfalta/PoshADCS",
    "BloodHound-CE": "SpecterOps/BloodHound",
    "sprayhound": "Hackndo/sprayhound",
    "LAPSToolkit": "leoloobeek/LAPSToolkit",
    "Max": "knavesec/Max",
    "krbjack": "almandin/krbjack",
    "DPAPI-Discover": "kr1tzy/DPAPI-Discover",
    "FadCrypt": "fareedfauzi/FadCrypt",
    "ShellcodeEncrypt2DLL": "restkhz/ShellcodeEncrypt2DLL",
    "NyxInvoke": "lkarlslund/NyxInvoke",
    "GoExec": "TheManticoreProject/GoExec",
    "goncat": "rouge-spectre/goncat",
    "gorsh": "k8gege/gorsh",
    "reverse_ssh": "NHAS/reverse_ssh",
    "pyjailbreaker": "jailctf/pyjailbreaker",
    "react2shell": "p3ta00/react2shell-poc",
    "sqlmapcg": "alex14324/sqlmapcg",
    "nanodump": "helpsystems/nanodump",
    "Inveigh-py": "Kevin-Robertson/Inveigh",
    "tools4mane": "manesec/tools4mane",
    "patronusx": "Michaeladsl/Patronusx",
    "webcrack": "j4k0xb/webcrack",
    "kernelinit": "Myldero/kernelinit",
    "webcrypt": "doyensec/webcrypt",
    "fadcrypt": "fareedfauzi/FadCrypt",
    "bugchecker": "vitoplantamura/BugChecker",
    "dwarf2json": "volatilityfoundation/dwarf2json",
    "logonsessionauditor": "FuzzySecurity/LogonSessionAuditor",
    "totalrecall": "xaitax/TotalRecall",
    "snaffler": "SnaffCon/Snaffler",
    "shieldengine": "fox-it/ShieldEngine",
    "FirmWalker": "craigz28/firmwalker",
    "firmware-mod-kit": "rampageX/firmware-mod-kit",
    "firmware-analysis-toolkit": "attify/firmware-analysis-toolkit",
    "firmadyne": "firmadyne/firmadyne",
    "sasquatch": "devttys0/sasquatch",
    "routersploit": "threat9/routersploit",
    "binwalk": "ReFirmLabs/binwalk",
    "avml": "microsoft/avml",
    "LiME": "504ensicsLabs/LiME",
    "profiles": "volatilityfoundation/profiles",
    "fenjing-py": "Marven11/Fenjing",
    "libc-database": "niklasb/libc-database",
    "PowerCat": "besimorhino/powercat",
    "Nishang": "samratashok/nishang",
    "Ruler": "sensepost/ruler",
    "AAD-Internals": "Gerenios/AADInternals",
    "msolspray": "dafthack/MSOLSpray",
    "Azucar": "nccgroup/azucar",
    "PMapper": "nccgroup/PMapper",
    "SteppingStones": "nccgroup/SteppingStones",
    "GraphRunner-py": "dafthack/GraphRunner",
    "ConfluencePot": "p3ta00/react2shell-poc",
    "RustHound": "OPENCYBER-FR/RustHound",
    "Nimbusc2": "rsmudge/CobaltStrike-VirtualBox",
    "EsxiArgs": "lipa-tools/lipa-tools",
    "Aerospace-Cybersecurity": "r0r0x-xx/AeroSpace-Cybersecurity",
    "100-redteam-projects": "kurogai/100-redteam-projects",
    "awesome-malware-analysis": "rshipp/awesome-malware-analysis",
    "awesome-reversing": "HACKE-RC/awesome-reversing",
    "awesome-lol-commonly-abused": "Stage1Online/Awesome-LOL-Commonly-Abused",
    "awesome-lolbins-and-beyond": "sheimo/awesome-lolbins-and-beyond",
    "cybersecurity_cheatsheets": "puzzithinker/cybersecurity_cheatsheets",
    "sliver-cheatsheet": "Snowming04/sliver-cheatsheets",
    "powershell-obfuscation-bible": "t3l3machus/PowerShell-Obfuscation-Bible",
    "securitytips": "hackerscrolls/SecurityTips",
    "eventlog_compendium": "nasbench/Eventlog_Compendium",
    "the_nsa_selector": "wenzellabs/the_NSA_selector",
    "reverse-engineering": "mytechnotalent/Reverse-Engineering",
    "megasheet": "p3ta00/megasheet",
    "payloadsallthethings": "swisskyrepo/PayloadsAllTheThings",
    "100redteam": "kurogai/100-redteam-projects",
}


def safe_name(name: str) -> str:
    return re.sub(r'[^A-Za-z0-9_-]', '_', name).lower()


def fetch_url(url: str, timeout: int = 8) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "portalgun/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if r.status == 200:
            return r.read()
    return b""


def fetch_readme(owner_repo: str) -> bytes:
    """Try multiple branches to find a README."""
    for branch in ("HEAD", "main", "master"):
        for name in ("README.md", "Readme.md", "readme.md"):
            url = f"https://raw.githubusercontent.com/{owner_repo}/{branch}/{name}"
            try:
                content = fetch_url(url)
                if content and len(content) > 100:
                    return content
            except urllib.error.HTTPError:
                continue
            except Exception:
                continue
    return b""


import shutil
import subprocess
_GH = shutil.which("gh")


def github_search(query: str) -> str:
    """Search GitHub for the most likely repo. Returns owner/repo or ''.

    Prefer authenticated `gh api` (5000/hr) over unauthenticated REST (60/hr).
    """
    if _GH:
        try:
            r = subprocess.run(
                [_GH, "api", "-X", "GET", "/search/repositories",
                 "-f", f"q={query}", "-f", "sort=stars", "-f", "order=desc", "-f", "per_page=1"],
                capture_output=True, text=True, timeout=15,
            )
            if r.returncode == 0 and r.stdout:
                data = json.loads(r.stdout)
                items = data.get("items", [])
                if items:
                    return items[0].get("full_name", "")
        except Exception:
            pass
        return ""
    url = f"https://api.github.com/search/repositories?q={urllib.parse.quote(query)}&sort=stars&order=desc&per_page=1"
    try:
        content = fetch_url(url, timeout=10)
        if not content:
            return ""
        data = json.loads(content)
        items = data.get("items", [])
        if items:
            return items[0].get("full_name", "")
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print(f"  RATE LIMITED — stopping search", file=sys.stderr)
            return "__RATELIMIT__"
    except Exception:
        pass
    return ""


def main() -> int:
    if not STATIC_TOOLS.exists():
        print(f"Missing {STATIC_TOOLS} — run extraction first", file=sys.stderr)
        return 1

    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    with STATIC_TOOLS.open() as f:
        tools = json.load(f)

    # Load existing mapping (resume support)
    mapping = {}
    if MAPPING_FILE.exists():
        try:
            mapping = json.loads(MAPPING_FILE.read_text())
        except Exception:
            mapping = {}

    ok = skipped = failed = searched = 0
    rate_limited = False

    for i, tool in enumerate(tools, 1):
        name = tool["name"]
        if name in mapping and Path(mapping[name].get("readme_path", "")).is_file():
            skipped += 1
            continue

        owner_repo = KNOWN_REPOS.get(name, "")

        # Fall back to GitHub search if no known mapping (and not rate limited)
        if not owner_repo and not rate_limited:
            print(f"  [{i}/{len(tools)}] searching for {name}...", file=sys.stderr)
            result = github_search(f"{name} in:name")
            if result == "__RATELIMIT__":
                rate_limited = True
            elif result:
                owner_repo = result
                searched += 1
                # gh is authenticated (5000/hr) so light politeness only
                time.sleep(0.2 if _GH else 2)

        if not owner_repo:
            failed += 1
            continue

        content = fetch_readme(owner_repo)
        if not content:
            failed += 1
            continue

        out_path = CACHE_DIR / f"{safe_name(name)}.md"
        out_path.write_bytes(content)
        mapping[name] = {
            "readme_path": str(out_path),
            "repo_url": f"https://github.com/{owner_repo}",
        }
        ok += 1
        if ok % 10 == 0:
            MAPPING_FILE.write_text(json.dumps(mapping, indent=2))
            print(f"  progress: {ok} fetched, {skipped} skipped, {failed} failed", file=sys.stderr)

    MAPPING_FILE.write_text(json.dumps(mapping, indent=2))
    print(f"\nDONE: {ok} fetched (incl. {searched} via search), {skipped} cached, {failed} failed", file=sys.stderr)
    print(f"Cache: {CACHE_DIR}")
    print(f"Mapping: {MAPPING_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
