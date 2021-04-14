#!/usr/bin/bash

CIDR_LIST=${CIDR_LIST:-}
CIDR_URL=${CIDR_URL:-"https://www.cloudflare.com/ips-v4"}

fping_interval=1
fping_count=3
fping_period=1000
st_url=https://speed.cloudflare.com/__down?bytes=125000000
st_parallel=10
st_line=100
print_line=10
quiet=false

function parse_args() {
    while getopts ":f:u:p:n:lq" opt; do
        case "$opt" in
        f)
            fping_count=$OPTARG
            ;;
        u)
            st_url=$OPTARG
            ;;
        p)
            st_parallel=$OPTARG
            ;;
        n)
            st_line=$OPTARG
            ;;
        l)
            print_line=$OPTARG
            ;;
        q)
            quiet=true
            ;;
        *) ;;
        esac
    done
    shift $((OPTIND - 1))
}

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
    cidr_to_iplist "1.0.0.0/24"
    cidr_to_iplist "1.1.1.0/24"
    if [ -n "$CIDR_LIST" ]; then
        for cidr in $CIDR_LIST; do
            cidr_to_iplist "$cidr"
        done
    elif [ -n "$CIDR_URL" ]; then
        local domain=$(echo $CIDR_URL | awk -F/ '{print $3}')
        local ip=$(dig +short $domain @1.1.1.1 | head -1)
        local scheme=$(echo $CIDR_URL | awk -F/ '{print $1}')
        local port=$([[ "$scheme" =~ "https" ]] && echo 443 || echo 80)
        curl -sSL --retry 3 --resolve $domain:$port:$ip $CIDR_URL | while read -r line; do
            cidr_to_iplist "$line"
        done
    fi
}

function check_file_exists() {
    for file in "$@"; do
        [ -f "$file" ] || exit 1
    done
}

function process_fping() {
    check_file_exists $1
    fping -f $1 -q -i ${2:-10} -c ${3:-1} -p ${4:-5000} |& awk '{split($5,a,"/"); split($8,b,"/"); if($8) print $1,a[2],b[2]}' | sort -k2,2rn -k3,3n
}

function speedtest() {
    check_file_exists $1
    rm -rf speedtest_tmpdir || :
    mkdir speedtest_tmpdir
    local url=${2:-"https://speed.cloudflare.com/__down?bytes=125000000"}
    local domain=$(echo $url | awk -F/ '{print $3}')
    local scheme=$(echo $url | awk -F/ '{print $1}')
    local port=$([[ "$scheme" =~ "https" ]] && echo 443 || echo 80)
    head -n ${4:-100} $1 | xargs -L 1 -P ${3:-10} sh -c "curl --resolve $domain:$port:\$0 --url $url -o speedtest_tmpdir/\$0 -s --connect-timeout 2 -m 10 || :"
    find -path './speedtest_tmpdir/*' -type f -printf '%f %s\n' | sort -k2,2rn
}

function print_result() {
    check_file_exists $1 $2
    if [ -n "$3" ]; then
        awk 'NR==FNR{a[$1]=$2;b[$1]=$3;next}{printf "%s\r\033[18Cpackets received: %s\033[3Cping: %s\033[3Cspeed: %.2f MB/s\n",$1,a[$1],b[$1],$2/10485760}' $1 $2 | head -n $3
    else
        awk 'NR==FNR{a[$1]=$2;b[$1]=$3;next}{printf "%s\r\033[18Cpackets received: %s\033[3Cping: %s\033[3Cspeed: %.2f MB/s\n",$1,a[$1],b[$1],$2/10485760}' $1 $2
    fi
}

function main() {
    parse_args "$@"
    local workdir=$(mktemp -d) && trap "rm -rf $workdir; exit 130" SIGINT
    cd $workdir
    $quiet || echo "Working directory: $workdir"
    local ip_result=${workdir:-.}/ips
    local fping_result=${workdir:-.}/ips_fping
    local speedtest_result=${workdir:-.}/ips_speedtest
    get_iplist $CIDR_URL >$ip_result
    $quiet || echo "$(wc -l <$ip_result) ips have been generate"
    process_fping $ip_result $fping_interval $fping_count $fping_period >$fping_result
    $quiet || echo "$(wc -l <$fping_result) ips have been ping"
    speedtest $fping_result $st_url $st_parallel $st_line >$speedtest_result
    $quiet || echo "$(wc -l <$speedtest_result) ips have been speedtest"
    print_result $fping_result $speedtest_result $print_line
    rm -rf ${workdir:-"$(pwd)"}
}

main "$@"
