#!/bin/bash

# mt.sh version num
# 1.03 for simple IO board
# 1.03_a add GPIO single debug
# 1.04 fixed gpio test
# 1.05 fixed gpio test and print refine
VERSION="simple-ver1.05-20240621"

COLOR_R='\033[0;31m'
COLOR_G='\033[0;32m'
COLOR_Y='\033[0;33m'
COLOR_O='\033[0m'
ECHO="echo -e"
cur_dir=$(pwd)
index=0
gpio_array1=(60 70 71 80 81 82 83 84 85 76 77)
gpio_array2=(61 68 69 72 73 74 75 78 79)
gpio_status=(0 0 0 0 0 0 0 0 0 0 0)
ad=(0 3)
ad_st=(0 0)
ad_gpio=(76 77)
LOG_PREFIX="[simple-ver1.05 optimized]"
# temp
#gpio_array1=(84 60)
#gpio_array2=(85)
#ad=(2)
#ad_gpio=(60)

echo 23 | sudo tee /sys/class/gpio/export >/dev/null 2>&1
_gpio_config 23 in
usb3_type=$(cat /sys/class/gpio/GPIO23/value)
echo 23 | sudo tee /sys/class/gpio/unexport >/dev/null 2>&1

if [ "$usb3_type" = "1" ]; then
    # TYPE-A模式
    TESTS="DDR USB2 USB3.0-TYPEA RJ_45 WIFI HDMI TF_SD EMMC DDR_verify"
else
    # TYPEC模式
    TESTS="USB3.0-TYPEC GPIO"
fi


OK()
{
	index=$(($index + 1))
	remainder=$(($index % 2))
	if [ $index -gt 7 ]; then
		if [ $remainder -eq 0 ]; then
			$ECHO -n "$index.$1 [${COLOR_G}OK${COLOR_O}]"
		else	
			$ECHO "\t$index.$1 [${COLOR_G}OK${COLOR_O}]" 
		fi
	else
		$ECHO "$index.$1 [${COLOR_G}OK${COLOR_O}]" 
	fi
}

FAILED()
{
	index=$(($index + 1))
	remainder=$(($index % 2))
	if [ $index -gt 7 ]; then
		if [ $remainder -eq 0 ]; then
			$ECHO -n "$index.$1 [${COLOR_R}FAILED${COLOR_O}]" "$2"
		else	
			$ECHO "\t$index.$1 [${COLOR_R}FAILED${COLOR_O}]" "$2"
		fi
	else
		$ECHO "$index.$1 [${COLOR_R}FAILED${COLOR_O}]" "$2"
	fi
}

_mount()
{
	sudo mount $2 $3 2>/dev/null || FAILED $1 MOUNT_FAIL
}


_storage() {
    SRC=${cur_dir}/mt_data.src
    DST="$2/mt_data.dst"

    # 删除目标文件（如果存在）
    sudo rm -f "$DST"

    # 用 dd 拷贝文件内容，块大小1M（可调整）
    sudo dd if="$SRC" of="$DST" bs=1M status=none

    # 用 dd 读取文件内容，通过管道计算md5sum
    SRC_MD5=$(sudo dd if="$SRC" bs=1M status=none | md5sum | awk '{print $1}')
    DST_MD5=$(sudo dd if="$DST" bs=1M status=none | md5sum | awk '{print $1}')

    # 删除目标文件，保持干净
    sudo rm -f "$DST"

    if [ "$SRC_MD5" = "$DST_MD5" ]; then
        OK "$1"
    else
        FAILED "$1" "DATA_CMP"
    fi
}

_ping()
{
	NET_INFO="$(ifconfig $2 | grep inet)"
	if [ ! -n "$NET_INFO" ]; then
		FAILED $1 NO_IP
	else
	        IP=$(echo $NET_INFO | awk '{print $2}')
		router_ip=$(echo $IP | sed s/\.[0-9]*$/\.1/)
		#echo $router_ip
	        sudo ping -c1 -W1 $router_ip >/dev/null 2>&1 && OK $1 || FAILED $1 PING_FAIL
	fi
}


_gpio_export_all() {
    for gpio in "${gpio_array1[@]}" "${gpio_array2[@]}"; do
        if [ ! -d "/sys/class/gpio/GPIO$gpio" ]; then
            echo "$gpio" > /sys/class/gpio/export 2>/dev/null
            sleep 0.1
        fi
    done
}

_gpio_release_all() {
    for gpio in "${gpio_array1[@]}" "${gpio_array2[@]}"; do
        if [ -d "/sys/class/gpio/GPIO$gpio" ]; then
            echo "$gpio" > /sys/class/gpio/unexport 2>/dev/null
        fi
    done
}

_gpio_config() {
    # $1 = gpio num, $2 = direction(in/out), $3 = level(0/1 for out)
    GPIO_PATH="/sys/class/gpio/GPIO$1"

    # 导出GPIO，如果没导出
    if [ ! -d "$GPIO_PATH" ]; then
        echo "$1" > /sys/class/gpio/export 2>/dev/null
        sleep 0.2
    fi

    echo "$2" > "$GPIO_PATH/direction"

    if [ "$2" = "out" ]; then
        echo "$3" > "$GPIO_PATH/value"
    fi
}

_gpio_check() {
    # $1 = gpio num, $2 = expected level
    GPIO_PATH="/sys/class/gpio/GPIO$1"
    value=$(cat "$GPIO_PATH/value")
    if [ "$value" = "$2" ]; then
        return 0
    else
        return 1
    fi
}

_sarad_check() {
    # $1 = expected level 0/1
    # $2 = "status" or "check"
    # 采样次数
    local samples=2
    local total=0
    local avg=0
    local raw=0
    local stable_level=0

    for i in "${!ad[@]}"; do
        total=0
        for _ in $(seq 1 $samples); do
            raw=$(cat /sys/bus/iio/devices/iio:device0/in_voltage${ad[$i]}_raw)
            total=$((total + raw))
        done
        avg=$((total / samples))

        # 设定一个容错阈值，比如 3500 ~ 4500 之间都视为模糊区，保持原状态
        if [ "$avg" -lt 3500 ]; then
            stable_level=0
        elif [ "$avg" -gt 4500 ]; then
            stable_level=1
        else
            # 模糊区，保留之前状态，不认为变化
            stable_level=$1
        fi

        if [ "$2" = "status" ]; then
            if [ "$stable_level" != "$1" ]; then
                ad_st[$i]=1
            fi
        else
            if [ "$stable_level" = "$1" ] && [ "${ad_st[$i]}" = "0" ]; then
                OK "SARAD${ad[$i]}"
                OK "GPIO${ad_gpio[$i]}"
            else
                FAILED "SARAD${ad[$i]}"
                FAILED "GPIO${ad_gpio[$i]}"
            fi
        fi
    done
}

_usb_test()
{
	if [ ! -d "/mnt/$1" ]; then
		FAILED $1 NOT_FOUND
		return
	fi

	_storage $1 /mnt/$1
}

_gpio_debug()
{
	if [ "$1" = "init" ]; then
		_gpio_export_all
		ls /sys/class/gpio
		exit
	fi
	if [ "$1" = "deinit" ]; then
		_gpio_release_all
		ls /sys/class/gpio
		exit
	fi

	while true
	do
		# all gpio out high
		for i in ${!gpio_array1[@]}; do
			_gpio_config ${gpio_array1[$i]} out 1
		done
		for i in ${!gpio_array2[@]}; do
			_gpio_config ${gpio_array2[$i]} out 1
		done
		echo "High level"
		sleep 2
		for i in ${!gpio_array1[@]}; do
			_gpio_config ${gpio_array1[$i]} out 0
		done
		for i in ${!gpio_array2[@]}; do
			_gpio_config ${gpio_array2[$i]} out 0
		done
		echo "Low level"
		sleep 2
	done
}

_find_vid()
{
    local dev=$1
    local sys_path=$(udevadm info -q path -n "$dev" 2>/dev/null)
    [ -z "$sys_path" ] && return 1

    local full_path="/sys$sys_path"
    while [ "$full_path" != "/" ]; do
       if [ -f "$full_path/idVendor" ]; then
           cat "$full_path/idVendor"
           return 0
       fi
       full_path=$(dirname "$full_path")
    done
    return 1
}

_mount_usb_all_partitions()
{
    local dev_base=$1      # /dev/sda
    local base_name=$(basename "$dev_base")
    local mnt_root=$2      # /mnt/usb2.0 或 /mnt/USB-TYPEA 等

    sudo mkdir -p "$mnt_root" >/dev/null 2>&1

    local partitions=$(ls /dev/${base_name}?* 2>/dev/null)

    if [ -z "$partitions" ]; then
        # 无分区，挂载整个设备
        sudo mkdir -p "$mnt_root/$base_name" >/dev/null 2>&1
        sudo umount "$dev_base" >/dev/null 2>&1
        sudo mount "$dev_base" "$mnt_root/$base_name" >/dev/null 2>&1
    else
        # 有分区，分别挂载
        for part in $partitions; do
            part_name=$(basename "$part")
            sudo mkdir -p "$mnt_root/$part_name" >/dev/null 2>&1
            sudo umount "$part" >/dev/null 2>&1
            sudo mount "$part" "$mnt_root/$part_name" >/dev/null 2>&1
        done
    fi
}

USB2()
{
    for dev in /dev/sd?; do
        [ -b "$dev" ] || continue
        mount | grep -q "$dev" && continue

        vid=$(_find_vid "$dev")
        if [ "$vid" = "048d" ]; then
            _mount_usb_all_partitions "$dev" "/mnt/USB2.0"
            _usb_test USB2.0
            return
        fi
    done
    FAILED USB2.0 NOT_FOUND
}

USB3.0-TYPEA()
{
    for dev in /dev/sd?; do
        [ -b "$dev" ] || continue

        vid=$(_find_vid "$dev")
        [ "$vid" != "0951" ] && continue

        mount | grep -q "$dev" && continue

        _mount_usb_all_partitions "$dev" "/mnt/USB-TYPEA"
        _usb_test USB-TYPEA
        return
    done
    FAILED USB-TYPEA NOT_FOUND
}

USB3.0-TYPEC()
{
    for dev in /dev/sd?; do
        [ -b "$dev" ] || continue

        vid=$(_find_vid "$dev")
        [ "$vid" != "0951" ] && continue

        mount | grep -q "$dev" && continue

        _mount_usb_all_partitions "$dev" "/mnt/USB-TYPEC"
        _usb_test USB-TYPEC
        return
    done
    FAILED USB-TYPEC NOT_FOUND
}

TF_SD()
{
	sudo mount /dev/mmcblk1p2 /mnt 2>/dev/null
	if [ "$?" != "0" ]; then
		FAILED TF_SD MOUNT_FAIL
		return
	fi

	_storage TF_SD /mnt	
	sudo umount /mnt
}

HDMI()
{
	output=$(dmesg | grep -i "hdmi")
	if [ "$output" = "" ]; then
		FAILED HDMI
	else
		OK HDMI
	fi
}

EMMC()
{
	if [ ! -e /dev/mmcblk0p8 ]; then
		# || create new process and return/exit cant quit EMMC expectedly 
		#sudo mount /dev/mmcblk0p1 /mnt 2>/dev/null || (FAILED EMMC MOUNT_FAIL;return)
		#_mount EMMC /dev/mmcblk0p1 /mnt
		echo y | sudo mkfs -t ext4 /dev/mmcblk0 >/dev/null 2>&1
		sudo mount /dev/mmcblk0 /mnt 2>/dev/null
		if [ "$?" != "0" ]; then
			FAILED EMMC MOUNT_FAIL
			return
		fi
	else
		#_mount EMMC /dev/mmcblk0p8 /mnt
		sudo mount /dev/mmcblk0p8 /mnt 2>/dev/null
		if [ "$?" != "0" ]; then
			FAILED EMMC MOUNT_FAIL
			return
		fi
	fi

	_storage EMMC /mnt	
	sudo umount /mnt
}

AUDIO()
{
	# Required /lib/libtinyalsa.so
	if [ ! -f "/lib/libtinyalsa.so"]; then
		cp libtinyalsa.so /lib/
	fi
	
#	line=$(ls /dev/snd | grep pcm* | wc -l)
#	if [ $line = "10" ]; then
#		OK AUDIO
#	else
#		FAILED AUDIO
#		return
#	fi
	ls /dev/snd | grep -q "pcmC0D0c" && ls /dev/snd | grep -q "pcmC0D0p"
	if [ $? = "0" ]; then
		OK AUDIO
	else
		FAILED AUDIO
	fi

	#aplay -D hw:0,0 left_right_2ch_48k_16_le.wav
	while true
	do
		aplay /home/sunplus/mt_test/left_right_2ch_48k_16_le.wav
	done
}

MIPI_CSI()
{
	output=$(dmesg | grep ov5647 | grep "3-0036" | grep "match on")
	if [ "$output" = "" ]; then
		FAILED MIPI_CSI_IN5
	else
		OK MIPI_CSI_IN5
	fi
}

MIPI_DSI()
{
	output=$(dmesg | grep "connect_dev_name RASPBERRYPI_DSI_PANEL")
	if [ "$output" = "" ]; then
		FAILED MIPI_DSI
	else
		OK MIPI_DSI
	fi
}

RJ_45()
{
	_ping ETH eth0
}

WIFI()
{
	NETNAME=$(ls /sys/class/net | grep '^wl' | head -n 1)
	if [ -n "$NETNAME" ]; then
		SSID="BPI-FT"
		PASSWD="bananapi"
		CON_NAME="$SSID"

		nmcli connection delete "$CON_NAME" >/dev/null 2>&1
		nmcli connection add type wifi ifname "$NETNAME" con-name "$CON_NAME" ssid "$SSID" >/dev/null
		nmcli connection modify "$CON_NAME" wifi-sec.key-mgmt wpa-psk >/dev/null
		nmcli connection modify "$CON_NAME" wifi-sec.psk "$PASSWD" >/dev/null
		nmcli connection up "$CON_NAME" >/dev/null 2>&1

		_ping WIFI "$NETNAME"
	else
		FAILED WIFI NOT_FOUND_NET
	fi
}

GPIO() {
    _gpio_export_all

    # 第一步: GPIO_ARRAY1输出高，GPIO_ARRAY2输入检测
    for gpio in "${gpio_array2[@]}"; do
        _gpio_config "$gpio" in
    done

    for gpio in "${gpio_array1[@]}"; do
        _gpio_config "$gpio" out 1
    done

    sleep 0.2

    for i in "${!gpio_array2[@]}"; do
        _gpio_check "${gpio_array2[$i]}" 1
        ret=$?
        gpio_array[$i]=$((1 - ret))  # ret=0时表示值等于1，gpio_array[i]=1，否则0
    done

    # 检查 SARAD 连接状态，标记状态
    _sarad_check 1 status

    # 第二步: GPIO_ARRAY1输出低，GPIO_ARRAY2输入检测
    for gpio in "${gpio_array1[@]}"; do
        _gpio_config "$gpio" out 0
    done

    sleep 0.2

    for i in "${!gpio_array2[@]}"; do
        _gpio_check "${gpio_array2[$i]}" 0
        ret=$?
        if [ "${gpio_status[$i]}" = "0" ] && [ "$ret" = "0" ]; then
            OK "GPIO${gpio_array2[$i]}"
        else
            FAILED "GPIO${gpio_array2[$i]}"
        fi
    done

    # 检查 SARAD 连接状态输出
    _sarad_check 0

    # 第三步: 切换方向，GPIO_ARRAY2输出，GPIO_ARRAY1输入检测
    for i in "${!gpio_array2[@]}"; do
        _gpio_config "${gpio_array1[$i]}" in
    done

    for gpio in "${gpio_array2[@]}"; do
        _gpio_config "$gpio" out 1
    done

    sleep 0.2

    for i in "${!gpio_array2[@]}"; do
        _gpio_check "${gpio_array1[$i]}" 1
        ret=$?
        gpio_array[$i]=$((1 - ret))
    done

    # 第四步: GPIO_ARRAY2输出低，GPIO_ARRAY1输入检测
    for gpio in "${gpio_array2[@]}"; do
        _gpio_config "$gpio" out 0
    done

    sleep 0.2

    for i in "${!gpio_array2[@]}"; do
        _gpio_check "${gpio_array1[$i]}" 0
        ret=$?
        if [ "${gpio_status[$i]}" = "0" ] && [ "$ret" = "0" ]; then
            OK "GPIO${gpio_array1[$i]}"
        else
            FAILED "GPIO${gpio_array1[$i]}"
        fi
    done

    _gpio_release_all
}

All()
{
	for t in $TESTS; do $t; done
}

gen_func_list()
{
	if [ $1 = "" ]; then
		echo "[ERROR] PLS input test name!"
		exit 1
	fi
	ABSOLUTE_PATH=$(readlink -f $0)
	FUNC_LIST=$(sed -n "/^# func start$/,/^# func end$/p" $ABSOLUTE_PATH |\
		grep "()"|\
		awk -F'(' '{print $1}')
	
	echo $FUNC_LIST | grep -w "$1" >/dev/null 2>&1
	if [ "$?" = "0" ]; then
		return 0
	fi

	echo "[ERROR] No match test function!"
	exit 1
}

DDR() {
    rm -f /home/sunplus/mt_mcb/DDR.pid /home/sunplus/mt_mcb/DDR.txt 2>/dev/null
    
    stress --vm 2 --vm-bytes 200M --timeout 15 > /home/sunplus/mt_mcb/DDR.txt 2>&1 &
    echo $! > /home/sunplus/mt_mcb/DDR.pid
    
}

DDR_verify() {
    if [ ! -f /home/sunplus/mt_mcb/DDR.pid ]; then
        FAILED DDR TEST_NOT_STARTED
        return 1
    fi

    DDR_PID=$(cat /home/sunplus/mt_mcb/DDR.pid 2>/dev/null)
    TOTAL_TIMEOUT=23
    INTERVAL=5
    
    if ps -p $DDR_PID > /dev/null 2>&1; then
        echo -n "等待DDR测试剩余时间:"
        
        remaining=$TOTAL_TIMEOUT
        while [ $remaining -gt 0 ] && ps -p $DDR_PID &>/dev/null; do
            echo -n " ${remaining}s..."
            sleep $INTERVAL
            remaining=$((remaining-INTERVAL))
            
            if [ $remaining -lt $INTERVAL ] && [ $remaining -gt 0 ]; then
                sleep $remaining
                echo -n " ${remaining}s..."
                remaining=0
            fi
        done
        
        echo ""
        
        if timeout $TOTAL_TIMEOUT tail --pid=$DDR_PID -f /dev/null; then
            if grep -q "successful" /home/sunplus/mt_mcb/DDR.txt 2>/dev/null; then
                OK DDR
            else
                FAILED DDR STRESS_TEST_FAILED
            fi
        else
            FAILED DDR TIMEOUT_WAITING
            kill -9 $DDR_PID 2>/dev/null
        fi
    else
        if grep -q "successful" /home/sunplus/mt_mcb/DDR.txt 2>/dev/null; then
            OK DDR
			echo ""

        else
            FAILED DDR STRESS_TEST_FAILED
            echo ""
        fi
    fi

    rm -f /home/sunplus/mt_mcb/DDR.pid /home/sunplus/mt_mcb/DDR.txt 2>/dev/null
}


clear
sleep 0.5

echo $VERSION test
if [ "$1" = "2" ]; then
	echo "test 2"
	exit 0
fi

#debug
if [ "$1" = "gpio" ]; then
	_gpio_debug $2
	exit 0
fi	
#

if [ "$1" = "test" ]; then
	gen_func_list $2
	$2
	exit 0
fi

All 2>/dev/null
