# Rclone mount systemd service installation script
Of course, it was not my sole idea but someone needs to get the thing done. I hate to manually create the systemd service for mounting the rclone remotes, so I made the installation script to automate this routine. As I hate bash scripts, I have utilized the OpenAI ChatGPT and Claude to do the job but those services are still pretty dumb, so I had a lot of frustration when it adds something and ruins other things.

**Please, share any thoughts on making this script better! Especially in the part of remotes names handling, a proper mount options for any remote (as I want to make a "universal" systemd unit file).**