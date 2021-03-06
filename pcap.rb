#!/usr/bin/ruby

# a full ruby pcap file parser
# (c) Yoann Guillot 2009
# License : wtfplv2 (zoy.org)

class String ;  def h ; unpack('H*').first end end
class Integer ; def h ; '0x%x' % self end end
class NilClass ; def h ; '' end end

module Pcap
	module ReadInts
		def readlonglong; @endianness == :big ? ((readlong << 32) | readlong) : (readlong | (readlong << 32)) end
		def readlong;   read(4).unpack(@endianness == :big ? 'N' : 'V').first end
		def readshort;  read(2).unpack(@endianness == :big ? 'n' : 'v').first end
		def readbyte ;  read(1).unpack('C').first end
	end

	class Sbuf
		attr_accessor :pos, :str, :endianness
		include ReadInts
		def initialize(str, endianness = :big)
			@pos = 0
			@str = str
			@endianness = endianness
		end
		def read(len=-1)
			puts "short string!" if $VERBOSE and eos? and len > 0
			# len < 0 -> read up to len (-1 = read all)
			len = @str.length + len + 1 - @pos if len < 0
			@pos += len
			@str[@pos-len, len].to_s
		end
		def readsub(len=-1)
			self.class.new(read(len))
		end
		def eos? ; @pos >= @str.length end
	end

	class Capture
		def self.from(io)
			c = new
			c.from(io)
			c
		end

		def initialize ; end

		attr_accessor :io, :endianness, :version, :tz, :filelen, :futureap, :linktype

		include ReadInts
		def from(io)
			@io = io
			@endianness = :little
			case signature = readlong
			when 0xa1b2c3d4
			when 0xd4c3b2a1; @endianness = :big
			else raise "invalid signature #{'%x' % signature}"
			end

			@version = [readshort, readshort]
			@tz = readlong
			@filelen = readlong
			@futureap = readlong
			@linktype = readlong
			@linktype = :eth if @linktype == 1
			@linktype = :usb if @linktype == 220
		end

		def readpacket
			Packet.read(self)
		end

		def read(len); @io.read(len) end
		def eof? ; @io.closed? or @io.eof?  end
	end

	class Packet
		attr_accessor :cap, :length, :rawlen, :time, :pld

		def self.read(cap)
			p = new
			p.read(cap)
			p
		end

		def read(cap)
			@cap = cap
			@time = cap.readlong
			@time += cap.readlong / 1_000_000.0
			@rawlen = cap.readlong
			@length = cap.readlong
			endian = :little
			endian = @cap.endianness if @cap.linktype == :usb
			@pld = interpret(Sbuf.new(cap.read(@rawlen), endian))
		end

		def interpret(data)
			case @cap.linktype
			when :eth; Ethernet.from(data)
			when :usb; USB.from(data)
			else data.read
			end
		end

		def ip; pld.pld if pld.pld.kind_of?(IP) end
		def tcp; pld.pld.pld if ip and pld.pld.pld.kind_of?(TCP) end
		def udp; pld.pld.pld if ip and pld.pld.pld.kind_of?(UDP) end
		def icmp; pld.pld.pld if ip and pld.pld.pld.kind_of?(ICMP) end
		def usb; pld if pld.kind_of?(USB) end

		def inspect
			"<pcap time=#@time-#{Time.at(@time).strftime('%d/%m/%Y %H:%M:%S') rescue nil} length=#@length#{" caplen=#@rawlen" if @rawlen != @length}\n#{@pld.inspect}>"
		end
	end

	class Proto
		def self.from(str)
			n = new
			n.interpret(str)
			n
		end
		def parse_payload(data)
			data.read
		end
	end

	class Ethernet < Proto
		attr_accessor :src, :dst, :type, :pld, :crc
		def interpret(data)
			@src  = data.read(6).h.scan(/../).join(':')
			@dst  = data.read(6).h.scan(/../).join(':')
			@type = data.readshort
			@pld  = parse_payload(data.readsub) #readsub(-5)
			@crc  = data.readlong unless data.eos?
		end

		def parse_payload(data)
			IPAuto.from(data) || super(data)
		end

		def inspect
			"<eth src=#@src dst=#@dst type=#{@type.h}\n#{@pld.inspect}>"
		end
	end

	class IP < Proto
	end

	class IPAuto
		def self.from(data)
			return if data.eos?
			case data.str[data.pos, 1].unpack('C').first >> 4
			when 4; IPv4.from(data)
			when 6; IPv6.from(data)
			end
		end
	end

	class IPv4 < IP
		attr_accessor :vers, :hdrlen, :tos, :id, :flag, :frag, :ttl, :proto, :hcksum, :src, :dst, :opts, :pld

		def interpret(data)
			b = data.readbyte || 0
			@vers = b >> 4
			@hdrlen = (b & 0xf) * 4
			@tos = data.readbyte
			len = data.readshort || 0
			@id = data.readshort
			@frag = data.readshort
			@flag = @frag >> 13 if @frag
			@frag &= 0x1fff
			@ttl = data.readbyte
			@proto = data.readbyte
			@hcksum = data.readshort
			@src = data.read(4).to_s.unpack('C*').join('.')
			@dst = data.read(4).to_s.unpack('C*').join('.')
			@opts = data.read(@hdrlen-data.pos)
			@pld = parse_payload(data.readsub(len-data.pos))
		end

		def parse_payload(data)
		       	case @proto
			when 6; TCP.from(data)
			when 17; UDP.from(data)
			when 1; ICMP.from(data)
			else super(data)
			end
		end

		def inspect
			"<ip4 src=#@src dst=#@dst id=#{@id.h} flag=#@flag frag=#@frag ttl=#@ttl proto=#@proto tos=#@tos#{" hdrlen=#@hdrlen" if @hdrlen != 20}#{" opts="+@opts.inspect if @opts.length > 0}\n#{@pld.inspect}>"
		end
	end

	class IPv6 < IP
		attr_accessor :vers, :trafclass, :flowlabel, :proto, :ttl, :src, :dst, :headers, :pld

		def interpret(data)
			b = data.readlong
			@vers = (b >> 28) & 0xf
			@trafclass = (b >> 20) & 0xff
			@flowlabel = b & 0xfffff
			len = data.readshort
			@proto = data.readbyte
			@ttl = data.readbyte
			@src = data.read(16).unpack('n*').map { |i| i.to_s(16) }.join(':')
			@dst = data.read(16).unpack('n*').map { |i| i.to_s(16) }.join(':')
			@headers = [] # TODO
			@pld = parse_payload(data.readsub(len-data.pos))
		end

		def parse_payload(data)
			case @proto
			when 6; TCP.from(data)
			when 17; UDP.from(data)
			when 1; ICMP.from(data)
			else super(data)
			end
		end

		def inspect
			"<ip6 src=#@src dst=#@dst tc=#@trafclass flow=#{@flowlabel.h} ttl=#@ttl proto=#@proto#{" headers="+@headers.inspect if @headers.length > 0}\n#{@pld.inspect}>"
		end
	end

	class TCP < Proto
		attr_accessor :sport, :dport, :seq, :ack, :doff, :flags, :wsz, :cksum, :urgent, :opts, :pld

		def interpret(data)
			@sport = data.readshort
			@dport = data.readshort
			@seq = data.readlong
			@ack = data.readlong
			@doff = data.readbyte
			doff = @doff >> 4 << 2
			@flags = data.readbyte
			@wsz = data.readshort
			@cksum = data.readshort
			@urgent = data.readshort
			@opts = data.read(doff-data.pos)
			@pld = parse_payload(data.readsub)
		end
		def flags_s
			i = -1 ; %w[fin syn rst psh ack urg ece cwr].find_all { @flags[i+=1] > 0 }
		end

		def inspect
			"<tcp sport=#@sport dport=#@dport seq=#{@seq.h} ack=#{@ack.h} flag=#{@flags.h}-#{flags_s*','} doff=#@doff#{" opts="+@opts.inspect if @opts.length > 0}\n#{@pld.inspect}>"
		end
	end

	class UDP < Proto
		attr_accessor :sport, :dport, :cksum, :pld

		def interpret(data)
			@sport = data.readshort
			@dport = data.readshort
			len = data.readshort
			@cksum = data.readshort
			@pld = parse_payload(data.readsub(len-8))
		end

		def parse_payload(data)
			if [@sport, @dport].sort == [67, 68]
				BOOTP.from(data)
			else
				super(data)
			end
		end

		def inspect
			"<udp sport=#@sport dport=#@dport\n#{@pld.inspect}>"
		end
	end

	class ICMP < Proto
		attr_accessor :type, :code, :cksum, :id, :seq, :pld

		def interpret(data)
			@type = data.readbyte
			@code = data.readbyte
			@cksum = data.readshort
			@id   = data.readshort
			@seq  = data.readshort
			@pld  = parse_payload(data.readsub)
		end

		def inspect
			"<icmp type=#@type code=#@code id=#{@id.h} seq=#@seq\n#{@pld.inspect}>"
		end
	end

	class BOOTP < Proto
		attr_accessor :dhcp, :unk1, :cip, :yip, :nip, :gip, :unk2, :magic, :dhcpoptions

		def interpret(data)
			@unk1 = data.read(12)
			@cip = data.read(4).to_s.unpack('C*').join('.')
			@yip = data.read(4).to_s.unpack('C*').join('.')
			@nip = data.read(4).to_s.unpack('C*').join('.')
			@gip = data.read(4).to_s.unpack('C*').join('.')
			@unk2 = data.read(236-12-4*4)
			@magic = data.readlong
			if @magic == 0x63825363
				@dhcpoptions = []
				until data.eos?
					type = data.readbyte
					len = data.readbyte
					opt = data.readsub(len) if len
					case type
					when 0
						next if len == 0
					when 53
						opt = opt.read
						b = opt[0, 1].unpack('C')[0]
						@dhcp = { 1 => 'dhcp discover', 2 => 'dhcp offer', 3 => 'dhcp request', 5 => 'dhcp ack' }[b[1]]
						opt = opt.inspect
					else
						opt = opt.read.inspect if len
					end
					@dhcpoptions << [type, opt]
				end
			end
		end

		def inspect
			opts = @dhcpoptions.sort_by { |t, d| t }.map { |t, d| "#{t}=#{d}" } if dhcpoptions
			"<#{@dhcp || 'bootp'} cip=#@cip yip=#@yip nip=#@nip gip=#@gip#{" dhcp_opts=[#{opts.join(', ')}]" if opts}>"
		end
	end

	class USB < Proto
		attr_accessor :id, :type, :xfer_type, :epnum, :devnum, :busnum, :flag_setup, :flag_data, :ts_sec, :ts_usec,
				:status, :length, :len_cap, :setup, :interval, :startframe, :xfer_flag, :ndesc, :pld
		def interpret(data)
			@id   = data.readlonglong
			@type = data.readbyte.chr.inspect[1...-1]
			@xfer_type = data.readbyte
			@epnum = data.readbyte
			@devnum = data.readbyte
			@busnum = data.readshort
			@flag_setup = data.readbyte
			@flag_data = data.readbyte
			@ts_sec = data.readlonglong
			@ts_usec = data.readlong
			@status = data.readlong
			@status = @status - (1 << 32) if @status > 0xfff00000
			@length = data.readlong
			@len_cap = data.readlong
			@setup = data.read(8)
			@interval = data.readlong
			@startframe = data.readlong
			@xfer_flag = data.readlong
			@ndesc = data.readlong
			@pld = data.read(@len_cap)
		end

		def endpoint
			"#@busnum:#@devnum:#@epnum"
		end

		def inspect
			"<usb id=#{@id.h} type=#@type xf=#@xfer_type ep=#{endpoint} status=#@status\n#{@pld.inspect}>"
		end
	end

	def self.dump_cli
		abort "usage: #$0 <pcapfile>" if ARGV.empty?
		p pc = Capture.from(ARGF)
		p pc.readpacket until pc.eof?
	end
end

if __FILE__ == $0
	Pcap.dump_cli
end

__END__
http://www.mail-archive.com/winpcap-users@winpcap.polito.it/msg02243.html
> Well, the page at
>
>         http://analyzer.polito.it/docs/advanced_man/how_to/add_new_lff.htm
>
> gives libpcap format as an example, although there are a few errors:
>
>         1) "File Length" is actually nominally "Significant
> Figures", which
> would, in theory, be the accuracy of time stamps, but, in practice, it's
> always zero and gives no information;
>
>         2) "Future Applications" is actually "Snapshot Length",
> which is the
> maximum number of packet data in any of the records of the file - or a
> value greater than or equal to that maximum, and is often 65535 (some
> software might use it to allocate a buffer into which to copy the packet
> data);
>
> and also:
>
>         1) "Time Zone" is often 0, so it can't be relied on to contain the
> offset of the time zone, at the location of the capture, from UTC in
> seconds;
>
>         2) "Link Type" shouldn't use the values 11, 12, 13, or 14
> - there are
> other values that should be used for those purposes - and has some other
> values that are available.

http://analyzer.polito.it/docs/advanced_man/how_to/add_new_lff.htm
At the beginning of the file there is an header. Here it is its format:
Magic Number
Major Version 	Minor Version
Time Zone
File Length
Future Applications
Link Type

Each file starts with a magic number. This number contains the hexadecimal sequence: 0xa1b2c3d4. It is used to understand if the file was generated by a little endian architecture or by a big endian architecture. In the little endian case the bytes sequence is: 0xa1, 0xb2, 0xc3, 0xd4; in the big endian case: 0xd4, 0xc3, 0xb2, 0xa.
Then there are two integers on two byte which represent the major and the minor version of the format.
An integer on 4 bytes which contains the time zone in relation with Greenwich.
An integer on 4 bytes which contains the file length.
An integer on 4 bytes reserved for future applications.
An integer on 4 bytes describes the link (Ethernet, ...). Complete mapping can be found into bpf.h file, into the WinPcap source pack. Here it it a table which show the values which this number can have and their meanings:

Value                        	Description
0 	no link-layer encapsulation
1 	Ethernet (10Mb)
2 	Experimental Ethernet (3Mb)
3 	Amateur Radio AX.25
4 	Proteon ProNET Token Ring
5 	Chaos
6 	IEEE 802 Networks
7 	ARCNET
8 	Serial Line IP
9 	Point-to-point Protocol
10 	FDDI
11 	LLC/SNAP encapsulated ATM
12 	Raw IP
13 	BSD/OS Serial Line IP
14 	BSD/OS Point-to-point Protocol

Then there are the packets; each packet has an header which contains the following information:
Packet Length
The packet part length contained in the file
Seconds from the capture beginning
Micro seconds from the capture beginning

An integer on 4 bytes for the packet length.
An integer on 4 bytes for the length of the packet part contained in the file. In fact can happen that the capture file does not contain the whole packet.
An integer on 4 bytes keeps the seconds number passed since the capture beginning until when the packet was captured.
An integer on 4 bytes keeps the microseconds number passed since the capture beginning until when the packet was captured.

// jj: from net2pcap.c, timestamp comes first
network packet formats from wikipedia
