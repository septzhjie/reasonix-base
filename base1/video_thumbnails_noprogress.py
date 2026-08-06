import os
import argparse
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# 支持的视频格式列表（可根据需要扩展）
VIDEO_EXTENSIONS = {".mp4", ".avi", ".mkv", ".mov", ".flv", ".wmv", ".webm"}

def find_video_files(root_dir):
    """
    递归遍历目录，查找所有视频文件。
    
    :param root_dir: 视频文件根目录
    :return: 视频文件路径列表
    """
    video_files = []
    for root, _, files in os.walk(root_dir):
        for file in files:
            if Path(file).suffix.lower() in VIDEO_EXTENSIONS:
                video_files.append(os.path.join(root, file))
    return video_files

def generate_thumbnail(video_path, time_offset="00:00:01"):
    """
    使用FFmpeg为单个视频生成封面。
    
    :param video_path: 视频文件路径
    :param time_offset: 截取帧的时间点（默认第1秒）
    :return: (成功状态, 错误信息)
    """
    video = Path(video_path)
    #output_path = video.with_suffix("-poster.jpg")  # 同名JPEG文件
    output_path = video.parent / (video.stem + "-poster.jpg")   # 同名JPEG文件
    
    # 如果封面已存在，跳过处理（避免重复操作）
    if output_path.exists():
        return True, "封面已存在，已跳过"
    
    # 构造FFmpeg命令[5,7](@ref)
    cmd = [
        "ffmpeg",
		"-c:v", "h264", # 强制指定解码器类型
		# --- 新增：增加缓存，减少直接 I/O 压力 ---
		#"-use_wallclock_as_timestamps", "1",
		#"-fflags", "+genpts", # 生成缺失的时间戳
		# --- 文件输入前增加缓存 ---
        "-i", str(video),
        "-ss", time_offset,       # 指定截取时间点
        "-vframes", "1",          # 只取1帧
        "-q:v", "2",              # 输出质量（2-31，值越小质量越高）
        "-y",                     # 覆盖已有文件
        str(output_path)
    ]
    
    try:
        # 执行命令[7](@ref)
        result = subprocess.run(
            cmd,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=300  # 超时时间（远程文件可能较慢）
        )
        return True, None
    except subprocess.CalledProcessError as e:
        return False, f"FFmpeg错误: {e.stderr.decode()}"
    except subprocess.TimeoutExpired:
        return False, "处理超时"

def main():
    parser = argparse.ArgumentParser(description="批量生成视频封面（针对远程挂载目录优化）")
    parser.add_argument("input_dir", help="视频文件根目录（支持多层目录）")
    parser.add_argument("-t", "--time", default="00:00:01", help="截取帧的时间点（默认：00:00:01）")
    parser.add_argument("-w", "--workers", type=int, default=4, help="并发线程数（默认：4）")
    args = parser.parse_args()
    
    # 检查输入目录
    if not os.path.isdir(args.input_dir):
        print("错误：输入目录无效")
        return
    
    # 查找所有视频文件
    video_files = find_video_files(args.input_dir)
    if not video_files:
        print("未找到视频文件（支持格式：%s）" % ", ".join(VIDEO_EXTENSIONS))
        return
    
    print(f"找到 {len(video_files)} 个视频文件，开始生成封面（线程数：{args.workers}）...")
    
    # 多线程处理[10,11](@ref)
    success_count = 0
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        # 提交任务
        future_to_video = {
            executor.submit(generate_thumbnail, video, args.time): video 
            for video in video_files
        }
        
        # 等待任务完成并统计结果
        for future in as_completed(future_to_video):
            video = future_to_video[future]
            try:
                success, error = future.result()
                if success:
                    success_count += 1
                else:
                    print(f"失败：{Path(video).name} - {error}")
            except Exception as e:
                print(f"异常：{Path(video).name} - {str(e)}")
    
    print(f"处理完成！成功：{success_count}/{len(video_files)}")

if __name__ == "__main__":
    main()
