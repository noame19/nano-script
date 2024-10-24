#!/bin/bash
#该脚本自动压缩input目录下的指定格式的视频文件成h264 x acc 视频编码，可自定义码率，已压缩或不符合压缩条件的将跳过。
#注意：需要系统安装好ffmpge、ffprobe,压缩检测无误后自动替换源文件，并增加batch后缀，请提前做好文件备份，备份！！
#压缩错误原因和路径全部记录至fail目录中
#Author: noame19
#Time: Thu 24 Oct 2024 12:02:31 AM CST
###==============设置部分========================
# 输入路径、压缩临时输出路径、日志路径
INPUT_DIR="/home/fff"
OUTPUT_DIR="/home/test/output"
LOG_DIR="/home/test/logs"


#设置处理器线程数和压缩分辨率码率（单位：kbps）
#关于不标准分辨率的视频，会以现有4k的码率，进行等像素比缩小码率
#小于720p或大于4k的视频，分别重命名lo_skip、la_skip后跳过
THREADS="16"
BR_720p="2500"
BR_1080p="5600"
BR_4k="18432"
BR_AUDIO="165"
# 需要处理的视频格式，可手动调整，多视频音频流的mkv文件可能会出错
VIDEO_EXT=("mp4" "mkv" "mov" "m4v")

#压缩错误判定时长，如：不在2s内则判定两个文件不一致，压缩错误
JUDGE_TIME="2"
#压缩错误最大重试次数
MAX_TRY="3"

###==================================================

LOG_FILE_ALL="$LOG_DIR/video_log_$(date +%Y%m%d).txt"
LOG_FILE_FAIL="$LOG_DIR/video_fail_$(date +%Y%m).txt"

# 日志写入
write_log() {
    local level=$1
    local message=$2
    local log_file=$3
    #echo "[$level|$(date +%Y%m%d_%H%M%S)] $message" >> "$log_file"
	printf "[%s | %s] %s\n" "$level" "$(date +%Y%m%d_%H%M%S)" "$message" >> "$log_file"
}

#单位转换
convert_size() {
    size=$1
    if [ "$size" -ge 1099511627776 ]; then  # 大于等于1TB
        echo "$(awk "BEGIN {printf \"%.2f TB\", $size / 1099511627776}")"
    elif [ "$size" -ge 1073741824 ]; then  # 大于等于1GB
        echo "$(awk "BEGIN {printf \"%.2f GB\", $size / 1073741824}")"
    elif [ "$size" -ge 1048576 ]; then  # 大于等于1MB
        echo "$(awk "BEGIN {printf \"%.2f MB\", $size / 1048576}")"
    else  # 小于1MB
        echo "$(awk "BEGIN {printf \"%.2f KB\", $size / 1024}")"
    fi
}

clean() {
	# 清理30天过期日志文件
    find "$LOG_DIR" -type f -name "video_log_*.txt"  -mtime +30 -exec rm {} \;
    find "$LOG_DIR" -type f -name "video_fail_*.txt" -mtime +30 -exec rm {} \;
	rm -rf "$OUTPUT_DIR"
}

# 获取重试次数函数
get_retry_count() {
    grep -o "$input_file" "$LOG_FILE_FAIL" | wc -l
}
	
# 获取视频时长
# get_video_duration() {
	# #ffmpeg -i "$1" 2>&1 | grep "Duration" | awk '{print $2}' | tr -d ',' | cut -d'.' -f1
# }

# 使用ffprobe获取视频信息：分辨率,时长
get_video_info() {
	# 如果流数量大于2，则进行转封装临时文件，再进行时长获取
	stream_count=$(ffprobe -v error -show_format -show_entries format=nb_streams -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | sed -n '1p')
	if [ $stream_count -gt 2 ]; then
		temp_file="$OUTPUT_DIR/temp.mp4"
		write_log "info" "stream $stream_count,cover to stream1.temp $1" "$LOG_FILE_ALL"
		ffmpeg -i "$1" -c copy -map 0:v -map 0:a -sn -f mp4 "$temp_file" #-sn禁用字幕复制
		ffprobe -v error -select_streams v:0 -show_entries stream=width,height,bit_rate -of default=noprint_wrappers=1:nokey=1 "$temp_file" 2>/dev/null
		ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_file" 2>/dev/null | cut -d'.' -f1
		ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$temp_file" 2>/dev/null
		rm -f "$temp_file"  # 删除临时文件
	else
		ffprobe -v error -select_streams v:0 -show_entries stream=width,height,bit_rate -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null
		ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | cut -d'.' -f1
		ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null
	fi
}

# 主函数
main() {
	if [ ! -d "$LOG_DIR" ]; then
		mkdir -p "$LOG_DIR"
	fi
	if [ ! -d "$OUTPUT_DIR" ]; then
		mkdir -p "$OUTPUT_DIR"
	fi
    clean
	#创建log文件夹

	echo "============================" >> "$LOG_FILE_ALL"
	echo "" >> "$LOG_FILE_ALL"
    echo "Compress misson started at $(date)" >> "$LOG_FILE_ALL"
    total_count=0
    done_count=0
    fail_count=0
    skip_count=0
	
	# 根据扩展名设置find参数
    find_expr=""
    for ext in "${VIDEO_EXT[@]}"; do
        if [ -n "$find_expr" ]; then
            find_expr="$find_expr -o -name *.$ext"
        else
            find_expr="-name *.$ext"
        fi
    done
	
    # 获取压缩前目录大小
    before_size=$(du -sb "$INPUT_DIR" | awk '{print $1}')
	
	#排除 _batch 、 _kip 、 _fail，find结果保存数组files
    mapfile -t files < <(find "$INPUT_DIR" -type f \( $find_expr \) ! -name "*batch.*" ! -name "*skip.*" ! -name "*fail.*")

    # 遍历文件列表
	for input_file in "${files[@]}"; do
	
		# 获取文件+扩展名、文件名、扩展名
		filename_ext=$(basename "$input_file")
		filename=$(basename "${input_file%.*}")
		ext="${input_file##*.}"
		
        # 获取视频流码率、分辨率、时长
		video_info=$(get_video_info "$input_file")
        
        # 分离宽度、高度、码率、时长
        width=$(echo "$video_info" | sed -n '1p')
        height=$(echo "$video_info" | sed -n '2p')
        vbitrate=$(echo "$video_info" | sed -n '3p' )
		vbitrate_kbps=$(echo "scale=0; $vbitrate / 1000" | bc)
		original_duration=$(echo "$video_info" | sed -n '4p' )
		abitrate=$(echo "$video_info" | sed -n '5p' )
		abitrate_kbps=$(echo "scale=0; $abitrate / 1000" | bc)

		
		# 检查是否获取到基础信息
		if [ -z "$width" ] || [ -z "$height" ] || [ -z "$vbitrate" ] || ! [[ "$height" =~ ^[0-9]+$ ]] || [ -z "$original_duration" ]; then
			write_log "fail" "info wrong ,width: $width, height: $height, bitrate: $vbitrate_kbps, duration: $original_duration, ${input_file%.$ext}_fail.$ext" "$LOG_FILE_ALL"
			write_log "fail" "info wrong ,width: $width, height: $height, bitrate: $vbitrate_kbps, duration: $original_duration, ${input_file%.$ext}_fail.$ext" "$LOG_FILE_FAIL"
			mv "$input_file" "${input_file%.$ext}_fail.$ext"
			fail_count=$((fail_count+1))
			total_count=$((total_count+1))
			continue
		fi
		
		# 设置最长边，最短边（考虑竖屏横屏）
		if [ "$width" -gt "$height" ]; then
			max_dim=$width
			min_dim=$height
		else
			max_dim=$height
			min_dim=$width
		fi

        # 设置压缩视频码率(自适应码率)
		if [ "$max_dim" -le 960 ]; then
			write_log "skip" "Resolution < 540p, Rename file and Skip ${input_file}" "$LOG_FILE_ALL"
			mv "$input_file" "${input_file%.$ext}lo_skip.$ext"
			skip_count=$((skip_count+1))
			total_count=$((total_count+1))
			continue
		elif [ "$max_dim" -eq 1280 ] && [ "$min_dim" -eq 720 ]; then
			vmax_bitrate=$BR_720p
		elif [ "$max_dim" -eq 1920 ] && [ "$min_dim" -eq 1080 ]; then
			vmax_bitrate=$BR_1080p
		elif [ "$max_dim" -eq 3840 ] && [ "$min_dim" -eq 2160 ]; then
			vmax_bitrate=$BR_4k
		elif [ "$min_dim" -gt 2160 ]; then
			write_log "skip" "Resolution > 4k,Rename file and Skip ${input_file}" "$LOG_FILE_ALL"
			mv "$input_file" "${input_file%.$ext}la_skip.$ext"
			skip_count=$((skip_count+1))
			total_count=$((total_count+1))
			continue
		else
			vmax_bitrate=$(echo "scale=0; $BR_4k * $width * $height / 3840 / 2160 " | bc)
		fi

		# 如果原视频码率低于或等于设定的最大视频码率，跳过压缩并重命名
		if [ "$vbitrate_kbps" -le "$vmax_bitrate" ]; then
			write_log "skip" "Bitrate has <= $vmax_bitrate kbps ,Rename file and Skip ${input_file}" "$LOG_FILE_ALL"
			# 重命名文件，添加_batch
			mv "$input_file" "${input_file%.$ext}_batch.$ext"
			skip_count=$((skip_count+1))
			total_count=$((total_count+1))
			continue
		fi
		
		# 设置压缩音频码率(原音频码率找不到，或大于设定的音码率则按设定音码率压缩)
		if [ ! -z "$abitrate_kbps" ] && [ "$abitrate_kbps" -gt "$BR_AUDIO" ]; then
			amax_bitrate="$BR_AUDIO"
		elif [ ! -z "$abitrate_kbps" ] && [ "$abitrate_kbps" -le "$BR_AUDIO" ]; then
			amax_bitrate="$abitrate_kbps"
		else
			amax_bitrate="$BR_AUDIO"
		fi
		
		# 使用哈希值规避重名问题
		hash_value=$(echo -n "$input_file" | md5sum | cut -d' ' -f1)
		FIN_OUTPUT_DIR="$OUTPUT_DIR/$hash_value"
		output_file="$FIN_OUTPUT_DIR/${filename}.mp4"
		if [ ! -d "$FIN_OUTPUT_DIR" ]; then
			mkdir -p "$FIN_OUTPUT_DIR"
		fi
		
		# 压缩视频，使用 2-pass 方式
		ffmpeg -y -i "$input_file" -c:v libx264 -b:v "${vmax_bitrate}k" -pass 1 -threads "${THREADS}" -an -f mp4 /dev/null && \
		ffmpeg -i "$input_file" -c:v libx264 -b:v "${vmax_bitrate}k" -pass 2 -threads "${THREADS}" -c:a aac -b:a "${amax_bitrate}k" "$output_file"
		rm -f ffmpeg2pass-*
		write_log "info" "video: ${vmax_bitrate}k, audio: ${amax_bitrate}k" "$LOG_FILE_ALL"
		
		# 匹配压缩前后时长，检测压缩后的文件是否正常,-s表示文件大小是否为空
        if [ -s "$output_file" ]; then
            compressed_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null | cut -d'.' -f1)
            if [ "$original_duration" -eq "$compressed_duration" ] || [ $((original_duration - compressed_duration)) -le $JUDGE_TIME ] && [ $((compressed_duration - original_duration)) -le $JUDGE_TIME ]; then
				write_log "done" "Compression Successful,bitrate: $vmax_bitrate,duration: $compressed_duration, ${input_file}" "$LOG_FILE_ALL"
				#printf "%s %s\n" "$output_file" "$input_file" >> "$LOG_FILE_DONE"
				rm -f "$input_file"
				mv "$output_file" "${input_file%.$ext}_batch.mp4"
				rm -rf "$FIN_OUTPUT_DIR"
                done_count=$((done_count+1))
				total_count=$((total_count+1))
            else
				retry_count=$((get_retry_count + 1))
				if [ "$retry_count" -ge "$max_try" ] || [ "$compressed_duration" -eq 0 ]; then
					mv "$input_file" "${input_file%.$ext}_fail.$ext"
				fi
				write_log "fail" "Compression Duration:$compressed_duration, no same as original:$original_duration, ${input_file}" "$LOG_FILE_FAIL"
				write_log "fail" "Compression Duration:$compressed_duration, no same as original:$original_duration, try $retry_count time, ${input_file}" "$LOG_FILE_ALL"
				rm -rf "$FIN_OUTPUT_DIR"
				fail_count=$((fail_count+1))
				total_count=$((total_count+1))
            fi
        else
            write_log "fail" "Compression Result is null , remove file, ${input_file}" "$LOG_FILE_ALL"
			write_log "fail" "Compression Result is null , remove file, ${input_file}" "$LOG_FILE_FAIL"
			rm -rf "$FIN_OUTPUT_DIR"
			mv "$input_file" "${input_file%.$ext}_fail.$ext"
            fail_count=$((fail_count+1))
			total_count=$((total_count+1))
        fi
    done
	
	 # 获取压缩后目录大小
    after_size=$(du -sb "$INPUT_DIR" | awk '{print $1}')
	
	# 计算差值和压缩率
	diff_size=$((before_size - after_size))
    if [ $diff_size -ge 0 ]; then
        size_change="释放"
		compression_ratio=$(echo "scale=2; $diff_size / $before_size * 100" | bc)
    else [ $diff_size -lt 0 ]
        diff_size=$((after_size - before_size))
        size_change="增加"
        compression_ratio=$(echo "scale=2; $after_size / $before_size * 100" | bc)
    fi
	
	# 格式化压缩率，添加百分号并保留两位小数
	#compression_ratio=$(printf "%.2f%%" "$compression_ratio")

	# 格式化差值的大小
    diff_size=$(convert_size "$diff_size")
	
    # 生成压缩任务汇总报告
	summary="本次共处理$total_count个视频, $fail_count个压缩失败,$skip_count个可跳过,$done_count个压缩成功,压缩后$size_change了$diff_size空间,压缩率为${compression_ratio}%"
    write_log "summ" "$summary" "$LOG_FILE_ALL"
	echo "$summary"

	echo "" >> "$LOG_FILE_ALL"

	if [ "$fail_count" -ne "0" ]; then
		echo "==============================" >> "$LOG_FILE_FAIL"
	fi
}

# 运行主函数
main
