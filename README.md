# DaVinci Resolve Scripts

These scripts are from a series of posts I made on the Blackmagic Design DaVinci Resolve user forum.

## Scripts/Utility/Timelines with Custom Settings

Currently the Media Pool in DaVinci Resolve doesn't have a way of showing whether a timeline
uses custom timeline settings or inherits from the project timeline settings. If it's not an
obvious difference, like a difference in resolution, you'd have to check the settings for each
one to find them all.

This script lists the timelines that have the "Use Project Settings" checkbox unchecked.
Double click a timeline to switch to it.

## Scripts/Utility/Libavutil

DaVinci Resolve comes with binaries for libavcodec, libavformat and libavutil.

This script is an example of how we can take advantage of having those libraries available to LuaJIT
in Resolve.

Specifically we'll use av_timecode_make_string() and av_timecode_init_from_string() to create and
parse timecode.

Be aware that DaVinci Resolve currently comes with libavutil-56, which creates incorrect timecode for
119.88fps drop frame (or any frame rate with drop frame above 59.94fps).

## Scripts/Utility/Grab Stills at Markers

A script that allows you to grab stills from timeline markers and optionally export them to a folder.

This script also highlights an issue with scripting in Resolve. There's no way to lock the user
interface while the script is running and if the user opens a modal window, like Project Settings,
most of the scriptable operations will fail. What's even worse, if the automatic backup kicks in when
a script is running, the script will also fail.

Many functions in the Resolve API can return a status so you can check if it succeeded or not, but I
think what we really need is a way to lock the GUI and for backups to be postponed while running. Just
like what happens when you're rendering a file.

## Scripts/Utility/Timeline Duration

A script that shows the duration of all timelines in a project using frames, timecode and real time.
This is useful for learning the real duration of a timeline when using a fractional frame rate, as it 
doesn't correspond exactly to its timecode.

## Scripts in Development

* Scripts/Utility/Render Clips by Guide Track
* Scripts/Edit/Timeline as 3D Shapes
