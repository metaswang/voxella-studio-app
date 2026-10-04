The synthetic 64×36 HEVC/hvc1 MP4 starts its video at 0.033008 seconds and silent AAC audio at zero. It reproduces the nonzero first presentation timestamp of trimmed videos without containing user media. Exact extraction at zero fails; the poster loader must accept the first available frame.

Generated with:

```sh
ffmpeg -itsoffset 0.033 -f lavfi -i color=c=teal:s=64x36:r=30 -f lavfi -i anullsrc=r=48000:cl=mono -t 0.1 -c:v libx265 -x265-params log-level=error:pools=1 -tag:v hvc1 -fps_mode passthrough -c:a aac session-poster-offset.mp4
```
