[Unit]
Description=Ops Monitor Weekly Summary

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ops-weekly-summary
