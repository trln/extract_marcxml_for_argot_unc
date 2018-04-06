args = ARGV
outpath = '/mnt/c/code/data/argot/'

if args.include?('-updatemta')
  Dir.chdir("/mnt/c/code/marc-to-argot") do
    system("git pull")
    system("rake install")
  end
end

if args.include?('-mta')
Dir.chdir("/mnt/c/code/data/marc") do
  Dir.glob("initial*").each do |infile|
    outfile = infile.gsub(/^(.*)\.xml/, 'add_\1.json')
    system("mta create unc #{infile} #{outpath}#{outfile}")
  end
end
end

if args.include?('-spofford')
Dir.chdir("/mnt/c/code/data/argot") do
  Dir.glob("add_*").each do |f|
    system("spofford ingest #{f}")
  end
end
end

