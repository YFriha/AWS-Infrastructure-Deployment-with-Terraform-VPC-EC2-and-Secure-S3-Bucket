add-content -path C:\Users\yassi\.ssh\config -value @'

Host dev-node
    ServerAliveInterval 30
    ServerAliveCountMax 6
    TCPKeepAlive yes
    HostName ${hostname}
    User ${user}
    IdentityFile ${identity_file }
'@