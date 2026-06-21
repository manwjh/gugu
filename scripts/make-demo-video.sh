#!/bin/bash
# Generate a short launch demo video without screen-recording permissions.
set -e
set -o pipefail
cd "$(dirname "$0")/.."

OUT_DIR="dist/launch-demo"
ASSETS="$OUT_DIR/assets"
SCENES="$OUT_DIR/scenes"
VIDEO="dist/gugu-demo-v2.3.0.mp4"
GIF="dist/gugu-demo-v2.3.0.gif"
LIST="$OUT_DIR/concat.txt"
FONT=".Hiragino-Sans-GB-Interface-W6"

mkdir -p "$ASSETS" "$SCENES" dist

swift build >/dev/null

for pose in front side happy wing tilt sleep; do
  ./.build/debug/gugu --render "$pose" "$ASSETS/$pose.png" >/dev/null
  magick "$ASSETS/$pose.png" -fuzz 8% -transparent "#efefef" -trim +repage "$ASSETS/$pose-trim.png"
done

make_scene() {
  local name="$1"
  local pose="$2"
  local title="$3"
  local subtitle="$4"
  local bubble="$5"
  local x="$6"
  local y="$7"
  local out="$SCENES/$name.png"

  magick -size 1280x720 xc:"#f7f4ef" \
    -fill "#e5ded3" -draw "rectangle 0,620 1280,720" \
    -fill "#ffffff" -stroke "#d6cec2" -strokewidth 2 -draw "roundrectangle 70,92 1210,570 18,18" \
    -fill "#1f2933" -pointsize 48 -font "$FONT" -annotate +100+170 "$title" \
    -fill "#46525f" -pointsize 30 -font "$FONT" -annotate +100+230 "$subtitle" \
    \( "$ASSETS/$pose-trim.png" -resize 250x250 \) -geometry +"$x"+"$y" -composite \
    "$out"

  if [ -n "$bubble" ]; then
    magick "$out" \
      -fill "#ffffff" -stroke "#d3c9bc" -strokewidth 2 -draw "roundrectangle 700,375 1135,455 16,16" \
      -fill "#1f2933" -pointsize 28 -font "$FONT" -annotate +728+425 "$bubble" \
      "$out"
  fi
}

make_scene 01_intro front "咕咕 Gugu" "一个活在 macOS 桌面上的 AI 小生命" "" 190 390
make_scene 02_body wing "有身体,会互动" "会走动、停靠、被拖拽,不是聊天机器人套皮" "" 560 390
make_scene 03_focus tilt "你专注时,它不打扰" "工作节奏只统计频率,不记录输入内容;心跳会冻结省 token" "" 870 390
make_scene 04_timing happy "择机开口" "不是你问它答,而是在合适的停顿说一句短话" "刚停下来呀?" 210 390
make_scene 05_privacy sleep "隐私优先,源码公开" "摄像头/麦克风默认关闭。原始画面和音频不上传、不保存。" "github.com/manwjh/gugu" 190 390

cat > "$LIST" <<EOF
file 'scenes/01_intro.png'
duration 4
file 'scenes/02_body.png'
duration 5
file 'scenes/03_focus.png'
duration 6
file 'scenes/04_timing.png'
duration 6
file 'scenes/05_privacy.png'
duration 5
file 'scenes/05_privacy.png'
duration 1
EOF

ffmpeg -y -f concat -safe 0 -i "$LIST" \
  -vf "scale=1280:720,format=yuv420p" \
  -c:v libx264 -r 30 -pix_fmt yuv420p -movflags +faststart "$VIDEO" >/dev/null 2>&1

ffmpeg -y -i "$VIDEO" -vf "fps=12,scale=640:-1:flags=lanczos" "$GIF" >/dev/null 2>&1

echo "$VIDEO"
echo "$GIF"
