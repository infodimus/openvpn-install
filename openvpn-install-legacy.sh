#!/bin/bash
# OpenVPN road warrior installer for Debian, Ubuntu and CentOS

# This script will work on Debian, Ubuntu, CentOS and probably other distros
# of the same families, although no support is offered for them. It isn't
# bulletproof but it will probably work if you simply want to setup a VPN on
# your Debian/Ubuntu/CentOS box. It has been designed to be as unobtrusive and
# universal as possible.


if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit 1
fi


if [[ ! -e /dev/net/tun ]]; then
	echo "TUN/TAP is not available"
	exit 2
fi


if grep -qs "CentOS release 5" "/etc/redhat-release"; then
	echo "CentOS 5 is too old and not supported"
	exit 3
fi

if [[ -e /etc/debian_version ]]; then
	OS=debian
	RCLOCAL='/etc/rc.local'
elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
	OS=centos
	RCLOCAL='/etc/rc.d/rc.local'
	# Needed for CentOS 7
	chmod +x /etc/rc.d/rc.local
else
	echo "Looks like you aren't running this installer on a Debian, Ubuntu or CentOS system"
	exit 4
fi

newclient () {
	# Generates the custom client.ovpn
	cp /etc/openvpn/client-common.txt ~/$1.ovpn
	echo "<ca>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/ca.crt >> ~/$1.ovpn
	echo "</ca>" >> ~/$1.ovpn
	echo "<cert>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/issued/$1.crt >> ~/$1.ovpn
	echo "</cert>" >> ~/$1.ovpn
	echo "<key>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/private/$1.key >> ~/$1.ovpn
	echo "</key>" >> ~/$1.ovpn
}


# Try to get our IP from the system and fallback to the Internet.
# I do this to make the script compatible with NATed servers (lowendspirit.com)
# and to avoid getting an IPv6.
IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$IP" = "" ]]; then
		IP=$(wget -qO- ipv4.icanhazip.com)
fi


if [[ -e /etc/openvpn/server.conf ]]; then
	while :
	do
	clear
		echo "Looks like OpenVPN is already installed"
		echo ""
		echo "What do you want to do?"
		echo "   1) Add a cert for a new user"
		echo "   2) Revoke existing user cert"
		echo "   3) Remove OpenVPN"
		echo "   4) Exit"
		read -p "Select an option [1-4]: " option
		case $option in
			1) 
			echo ""
			echo "Tell me a name for the client cert"
			echo "Please, use one word only, no special characters"
			read -p "Client name: " -e -i client CLIENT
			cd /etc/openvpn/easy-rsa/
			./easyrsa build-client-full $CLIENT nopass
			# Generates the custom client.ovpn
			newclient "$CLIENT"
			echo ""
			echo "Client $CLIENT added, certs available at ~/$CLIENT.ovpn"
			exit
			;;
			2)
			# This option could be documented a bit better and maybe even be simplimplified
			# ...but what can I say, I want some sleep too
			NUMBEROFCLIENTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$NUMBEROFCLIENTS" = '0' ]]; then
				echo ""
				echo "You have no existing clients!"
				exit 5
			fi
			echo ""
			echo "Select the existing client certificate you want to revoke"
			tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			if [[ "$NUMBEROFCLIENTS" = '1' ]]; then
				read -p "Select one client [1]: " CLIENTNUMBER
			else
				read -p "Select one client [1-$NUMBEROFCLIENTS]: " CLIENTNUMBER
			fi
			CLIENT=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$CLIENTNUMBER"p)
			cd /etc/openvpn/easy-rsa/
			./easyrsa --batch revoke $CLIENT
			./easyrsa gen-crl
			rm -rf pki/reqs/$CLIENT.req
			rm -rf pki/private/$CLIENT.key
			rm -rf pki/issued/$CLIENT.crt
			rm -rf /etc/openvpn/crl.pem
			cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
			echo ""
			echo "Certificate for client $CLIENT revoked"
			exit
			;;
			3) 
			echo ""
			read -p "Do you really want to remove OpenVPN? [y/n]: " -e -i n REMOVE
			if [[ "$REMOVE" = 'y' ]]; then
				PORT=$(grep '^port ' /etc/openvpn/server.conf | cut -d " " -f 2)
				if pgrep firewalld; then
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --zone=public --remove-port=$PORT/udp
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --zone=public --remove-port=$PORT/udp
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
				fi
				if iptables -L | grep -qE 'REJECT|DROP'; then
					sed -i "/iptables -I INPUT -p udp --dport $PORT -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -s 10.8.0.0\/24 -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT/d" $RCLOCAL
				fi
				sed -i '/iptables -t nat -A POSTROUTING -s 10.8.0.0\/24 -j SNAT --to /d' $RCLOCAL
				if which sestatus; then
					if sestatus | grep "Current mode" | grep -qs "enforcing"; then
						if [[ "$PORT" != '1194' ]]; then
							semanage port -d -t openvpn_port_t -p udp $PORT
						fi
					fi
				fi
				if [[ "$OS" = 'debian' ]]; then
					apt-get remove --purge -y openvpn openvpn-blacklist
				else
					yum remove openvpn -y
				fi
				rm -rf /etc/openvpn
				rm -rf /usr/share/doc/openvpn*
				echo ""
				echo "OpenVPN removed!"
			else
				echo ""
				echo "Removal aborted!"
			fi
			exit
			;;
			4) exit;;
		esac
	done
else
	clear
	echo 'Welcome to this quick OpenVPN "road warrior" installer'
	echo ""
	# OpenVPN setup and first user creation
	echo "I need to ask you a few questions before starting the setup"
	echo "You can leave the default options and just press enter if you are ok with them"
	echo ""
	echo "First I need to know the IPv4 address of the network interface you want OpenVPN"
	echo "listening to."
	read -p "IP address: " -e -i $IP IP
	echo ""
	echo "What port do you want for OpenVPN?"
	read -p "Port: " -e -i 1194 PORT
	echo ""
	echo "What DNS do you want to use with the VPN?"
	echo "   1) Current system resolvers"
	echo "   2) FDN (recommended)"
	echo "   3) OpenDNS"
	echo "   4) NTT"
	echo "   5) Google"
	echo "   6) Hurricane Electric"
	read -p "DNS [1-6]: " -e -i 1 DNS
	echo ""
	echo "Finally, tell me your name for the client cert"
	echo "Please, use one word only, no special characters"
	read -p "Client name: " -e -i client CLIENT
	echo ""
	echo "Okay, that was all I needed. We are ready to setup your OpenVPN server now"
	read -n1 -r -p "Press any key to continue..."
		if [[ "$OS" = 'debian' ]]; then
		apt-get update
		apt-get install openvpn iptables openssl ca-certificates -y
	else
		# Else, the distro is CentOS
		yum install epel-release -y
		yum install openvpn iptables openssl wget ca-certificates -y
	fi
	# An old version of easy-rsa was available by default in some openvpn packages
	if [[ -d /etc/openvpn/easy-rsa/ ]]; then
		rm -rf /etc/openvpn/easy-rsa/
	fi
	# Get easy-rsa
	wget -O ~/EasyRSA-3.0.1.tgz https://github.com/OpenVPN/easy-rsa/releases/download/3.0.1/EasyRSA-3.0.1.tgz
	tar xzf ~/EasyRSA-3.0.1.tgz -C ~/
	mv ~/EasyRSA-3.0.1/ /etc/openvpn/
	mv /etc/openvpn/EasyRSA-3.0.1/ /etc/openvpn/easy-rsa/
	chown -R root:root /etc/openvpn/easy-rsa/
	rm -rf ~/EasyRSA-3.0.1.tgz
	cd /etc/openvpn/easy-rsa/
	#Use 4096 bits DH instead of 2048 bits
	echo "set_var EASYRSA_KEY_SIZE 4096" > vars
	# Create the PKI, set up the CA, the DH params and the server + client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa gen-dh
	./easyrsa build-server-full server nopass
	./easyrsa build-client-full $CLIENT nopass
	./easyrsa gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/dh.pem pki/issued/server.crt pki/private/server.key /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn
	# Generate server.conf
	echo "port $PORT
proto udp
dev tun
sndbuf 0
rcvbuf 0
ca ca.crt
cert server.crt
key server.key
dh dh.pem
cipher AES-256-CBC
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" > /etc/openvpn/server.conf
	echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server.conf
	# DNS
	case $DNS in
		1) 
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		grep -v '#' /etc/resolv.conf | grep 'nameserver' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read line; do
			echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server.conf
		done
		;;
		2) 
		echo 'push "dhcp-option DNS 80.67.169.12"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 80.67.169.40"' >> /etc/openvpn/server.conf
		;;
		3)
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server.conf
		;;
		4) 
		echo 'push "dhcp-option DNS 129.250.35.250"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 129.250.35.251"' >> /etc/openvpn/server.conf
		;;
		5)
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server.conf
		;;
		6) 
		echo 'push "dhcp-option DNS 74.82.42.42"' >> /etc/openvpn/server.conf
		;;
	esac
	echo "keepalive 10 120
comp-lzo
persist-key
persist-tun
crl-verify crl.pem" >> /etc/openvpn/server.conf
	# Enable net.ipv4.ip_forward for the system
	if [[ "$OS" = 'debian' ]]; then
		sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
	else
		# CentOS 5 and 6
		sed -i 's|net.ipv4.ip_forward = 0|net.ipv4.ip_forward = 1|' /etc/sysctl.conf
		# CentOS 7
		if ! grep -q "net.ipv4.ip_forward=1" "/etc/sysctl.conf"; then
			echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
		fi
	fi
	# Avoid an unneeded reboot
	echo 1 > /proc/sys/net/ipv4/ip_forward
	# Set NAT for the VPN subnet
	iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP
	sed -i "1 a\iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP" $RCLOCAL
	if pgrep firewalld; then
		# We don't use --add-service=openvpn because that would only work with
		# the default port. Using both permanent and not permanent rules to
		# avoid a firewalld reload.
		firewall-cmd --zone=public --add-port=$PORT/udp
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --zone=public --add-port=$PORT/udp
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
	fi
	if iptables -L | grep -qE 'REJECT|DROP'; then
		# If iptables has at least one REJECT rule, we asume this is needed.
		# Not the best approach but I can't think of other and this shouldn't
		# cause problems.
		iptables -I INPUT -p udp --dport $PORT -j ACCEPT
		iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
		iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
		sed -i "1 a\iptables -I INPUT -p udp --dport $PORT -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" $RCLOCAL
	fi
	# If SELinux is enabled and a custom port was selected, we need this
	if which sestatus; then
		if sestatus | grep "Current mode" | grep -qs "enforcing"; then
			if [[ "$PORT" != '1194' ]]; then
				# semanage isn't available in CentOS 6 by default
				if ! which semanage > /dev/null 2>&1; then
					yum install policycoreutils-python -y
				fi
				semanage port -a -t openvpn_port_t -p udp $PORT
			fi
		fi
	fi
	# And finally, restart OpenVPN
	if [[ "$OS" = 'debian' ]]; then
		# Little hack to check for systemd
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
		else
			/etc/init.d/openvpn restart
		fi
	else
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
			systemctl enable openvpn@server.service
		else
			service openvpn restart
			chkconfig openvpn on
		fi
	fi
	# Try to detect a NATed connection and ask about it to potential LowEndSpirit users
	EXTERNALIP=$(wget -qO- ipv4.icanhazip.com)
	if [[ "$IP" != "$EXTERNALIP" ]]; then
		echo ""
		echo "Looks like your server is behind a NAT!"
		echo ""
		echo "If your server is NATed (LowEndSpirit), I need to know the external IP"
		echo "If that's not the case, just ignore this and leave the next field blank"
		read -p "External IP: " -e USEREXTERNALIP
		if [[ "$USEREXTERNALIP" != "" ]]; then
			IP=$USEREXTERNALIP
		fi
	fi
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
proto udp
sndbuf 0
rcvbuf 0
remote $IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
comp-lzo" > /etc/openvpn/client-common.txt
	# Generates the custom client.ovpn
	newclient "$CLIENT"
	echo ""
	echo "Finished!"
	echo ""
	echo "Your client config is available at ~/$CLIENT.ovpn"
	echo "If you want to add more clients, you simply need to run this script another time!"
fi