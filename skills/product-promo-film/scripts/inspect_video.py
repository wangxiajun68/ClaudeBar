#!/usr/bin/env python3
"""Read-only video checks; visual playback remains a separate review step."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import shutil
import subprocess
import sys


def inspect(args):
    video = Path(args.video).expanduser().resolve()
    if not video.is_file():
        raise ValueError(f'Video not found: {video}')
    if not shutil.which('ffprobe'):
        raise ValueError('ffprobe is required')
    command = ['ffprobe', '-v', 'error', '-show_entries',
               'format=duration:stream=codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,nb_frames,nb_read_frames',
               '-of', 'json']
    if args.count_frames:
        command.append('-count_frames')
    raw = json.loads(subprocess.check_output(command + [str(video)], text=True))
    streams = [s for s in raw.get('streams', []) if s.get('codec_type') == 'video']
    if len(streams) != 1:
        raise ValueError(f'Expected one video stream, found {len(streams)}')
    stream = streams[0]
    fps = float(Fraction(stream.get('avg_frame_rate', '0/1')))
    duration = float(raw['format']['duration'])
    frame_value = stream.get('nb_read_frames') or stream.get('nb_frames')
    frames = int(frame_value) if frame_value and frame_value != 'N/A' else None
    report = {'path': str(video), 'codec': stream.get('codec_name'),
              'pixel_format': stream.get('pix_fmt'), 'width': stream.get('width'),
              'height': stream.get('height'), 'fps': fps, 'duration': duration,
              'frames': frames, 'audio_streams': sum(s.get('codec_type') == 'audio'
                                                   for s in raw.get('streams', []))}
    failures = []
    for field, expected in [('width', args.width), ('height', args.height),
                            ('codec', args.codec), ('pixel_format', args.pixel_format),
                            ('frames', args.frames)]:
        if expected is not None and report[field] != expected:
            failures.append(f'{field}: expected {expected}, got {report[field]}')
    if args.fps is not None and abs(fps - args.fps) > 0.001:
        failures.append(f'fps: expected {args.fps}, got {fps}')
    tolerance = max(0.05, 1 / fps) if fps > 0 else 0.05
    if args.duration is not None and abs(duration - args.duration) > tolerance:
        failures.append(f'duration: expected {args.duration}, got {duration}')
    if args.decode:
        if not shutil.which('ffmpeg'):
            raise ValueError('ffmpeg is required for --decode')
        subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(video),
                        '-f', 'null', '-'], check=True, capture_output=True, text=True)
        report['complete_decode'] = 'passed'
    report['failures'] = failures
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('video')
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    parser.add_argument('--fps', type=float)
    parser.add_argument('--duration', type=float)
    parser.add_argument('--frames', type=int)
    parser.add_argument('--codec')
    parser.add_argument('--pixel-format')
    parser.add_argument('--count-frames', action='store_true', help='Count decoded video frames')
    parser.add_argument('--decode', action='store_true', help='Fail on full-decode errors')
    args = parser.parse_args()
    try:
        return inspect(args)
    except (ValueError, KeyError, ZeroDivisionError, subprocess.CalledProcessError) as error:
        detail = getattr(error, 'stderr', None) or str(error)
        print(f'Video inspection failed: {detail}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
