[Unit]
Description=Ops Monitor Threshold Check

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ops-threshold-check
