#!/usr/bin/bash

cidr_url=https://www.cloudflare.com/ips-v4

fping_interval=1
fping_count=3
fping_period=1000

st_url=https://speed.cloudflare.com/__down?bytes=125000000
st_parallel=10
st_num=100

print_num=10

function inet_aton() {
    echo $1 | awk -F'.' '{print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4}'
}

function inet_ntoa() {
    echo $(($1 / 16777216 % 256)).$(($1 / 65536 % 256)).$(($1 / 256 % 256)).$(($1 % 256))
}

# Get 1 random effective IP per class C from CIDR
function cidr_to_iplist() {
    base=$(inet_aton ${1%/*})
    mask=${1#*/}
    if [ "$mask" -lt 24 ]; then
        # /0 - /23
        count=$((2 ** (32 - mask) - 2))
        end=$((base + count))
        inet_ntoa $((base + 1 + RANDOM % 255)) # base address plus a random number between [1, 255] in 1st Class C
        base=$((base + 256))
        while ((base + 254 < end)); do
            inet_ntoa $((base + RANDOM % 256)) # base address plus a random number between [0, 255] in Class C between 1st and last
            base=$((base + 256))
        done
        inet_ntoa $((base + RANDOM % 255)) # base address plus a random number between [0, 254] in last Class C
    elif [ "$mask" -lt 31 ]; then
        # /24 - /30
        count=$((2 ** (32 - mask) - 2))
        inet_ntoa $((base + 1 + RANDOM % count)) # base address plus a random number between [1, count-1]
    elif [ "$mask" -lt 32 ]; then
        # /31
        inet_ntoa $((base + RANDOM % 2)) # base address plus a random number between [0, 1]
    else
        # /32
        inet_ntoa $base # base address is the only IP we can fetch
    fi
}

function get_iplist() {
    local cidrs=
    if [ $# -ge 1 ]; then
        case $1 in
        http* | https*)
            local url=$1
            local domain=$(echo $url | awk -F/ '{print $3}')
            local ip=$(dig +short $domain @1.1.1.1 | head -1)
            local scheme=$(echo $url | awk -F/ '{print $1}')
            local port=$([[ "$scheme" =~ "https" ]] && echo 443 || echo 80)
            cidrs=$(curl -sSL --retry 3 --resolve $domain:$port:$ip $url)
            ;;
        *)
            cidrs=$(cat $1)
            ;;
        esac
    else
        cidrs=$(cat -)
    fi
    echo "$cidrs" | while read -r line; do
        cidr_to_iplist $line
    done
}

function process_fping() {
    fping -q -i "${1:-10}" -c "${2:-1}" -p "${3:-5000}" 2>&1 || :
}

function sort_fping() {
    awk '{split($5,a,"/"); split($8,b,"/"); if($8) print $1,a[2],b[2]}' | sort -k2,2rn -k3,3n
}

function speedtest() {
    [ -d "speedtest_tmpdir" ] || mkdir speedtest_tmpdir
    local url=${1:-"https://speed.cloudflare.com/__down?bytes=125000000"}
    local domain=$(echo $url | awk -F/ '{print $3}')
    local scheme=$(echo $url | awk -F/ '{print $1}')
    local port=$([[ "$scheme" =~ "https" ]] && echo 443 || echo 80)
    head -n ${3:-100} | xargs -L 1 -P ${2:-10} sh -c "curl --resolve $domain:$port:\$0 --url $url -o speedtest_tmpdir/\$0 -s --connect-timeout 2 -m 10 || :"
    find -path './speedtest_tmpdir/*' -type f -printf '%f %s\n' | sort -k2,2rn
    rm -rf speedtest_tmpdir
}

function merge_result() {
    awk 'NR==FNR{a[$1]=$0;next}{print a[$1],$2}' $1 $2
}

function print_result() {
    if [ -n "$1" ]; then
        awk '{printf "  %s\r\033[18Cpackets received: %s\033[3Cping: %s\033[3Cspeed: %.2f MB/s\n",$1,$2,$3,$4/10485760}' | head -n $1
    else
        awk '{printf "  %s\r\033[18Cpackets received: %s\033[3Cping: %s\033[3Cspeed: %.2f MB/s\n",$1,$2,$3,$4/10485760}'
    fi
}

function main() {
    workdir=$(mktemp -d)
    pushd $workdir >/dev/null
    get_iplist >ips $cidr_url
    process_fping <ips >ips_fping $fping_interval $fping_count $fping_period
    sort_fping <ips_fping >ips_fping_sorted
    speedtest <ips_fping_sorted >ips_speedtest $st_url $st_parallel $st_num
    merge_result >ips_fping_speedtest ips_fping_sorted ips_speedtest
    print_result <ips_fping_speedtest $print_num
    popd >/dev/null
    rm -rf $workdir
}

main "$@"
