BEGIN {
    old = ARGV[1]
    new = ARGV[2]
    ARGV[1] = ARGV[2] = ""
}
s = index($0,old) { $0 = substr($0,1,s-1) new substr($0,s+length(old)) }
{ print }
