# 发布命令清单

这些命令需要 GitHub 登录态和仓库权限。执行前先确认没有把不想发布的本地 Swift 改动混进提交。

## 本地验证

```bash
swift build
GUGU_HOME=/private/tmp/gugu-launch-selftest-final ./.build/debug/gugu --selftest-offline
./scripts/make-demo-video.sh
```

## 建议提交发布材料

当前仓库里已有未提交 Swift 改动。若只提交发布材料,建议显式指定文件:

```bash
git add \
  Info.plist \
  README.md \
  CHANGELOG.md \
  LICENSE \
  .github \
  docs \
  scripts/make-demo-video.sh

git commit -m "Prepare v2.3.0 public launch"
```

## 设置 GitHub 仓库信息

```bash
gh repo edit manwjh/gugu \
  --description "An AI desktop lifeform for macOS. A little bird that senses your work rhythm, remembers, grows, and speaks at the right moment." \
  --add-topic macos \
  --add-topic swift \
  --add-topic spritekit \
  --add-topic ai-agent \
  --add-topic desktop-pet \
  --add-topic llm \
  --add-topic openai-compatible \
  --add-topic privacy-first
```

## 打 tag 并创建 Release

```bash
git tag v2.3.0
git push origin main
git push origin v2.3.0

gh release create v2.3.0 \
  --title "Gugu v2.3.0 - public launch release" \
  --notes-file docs/RELEASE_NOTES_v2.3.0.md \
  dist/gugu-demo-v2.3.0.mp4 \
  dist/gugu-demo-v2.3.0.gif
```

如果默认分支不是 `main`,把上面的 `main` 改成实际分支名。
