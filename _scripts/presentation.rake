
require 'pathname' #Pathname kütüphanesi
require 'pythonconfig' #Yapılandırmayı sağlayan kütüphane
require 'yaml' #Nesne serileştirme ve genel veri depolama için kullanılan kütüphane

CONFIG = Config.fetch('presentation', {}) #Sunum yapılandırmasında sunumlara ait bölümü al

PRESENTATION_DIR = CONFIG.fetch('directory', 'p') #Sunum dizini
DEFAULT_CONFFILE = CONFIG.fetch('conffile', '_templates/presentation.cfg') # Öntanımlı landslide yapılandırması
INDEX_FILE = File.join(PRESENTATION_DIR, 'index.html')  # Sunum indeksi
IMAGE_GEOMETRY = [ 733, 550 ] # sunuma eklenecek resimler için boyut tanımlama
DEPEND_KEYS    = %w(source css js) #Bağımlılıklar için yapılandırmada hangi anahtarlara bakılacak
DEPEND_ALWAYS  = %w(media) #Vara daima bağımlılık verilecek dosya/dizinler
TASKS = { #Hedef görevler ve tanımları
    :index   => 'sunumları indeksle',
    :build   => 'sunumları oluştur',
    :clean   => 'sunumları temizle',
    :view    => 'sunumları görüntüle',
    :run     => 'sunumları sun',
    :optim   => 'resimleri iyileştir',
    :default => 'öntanımlı görev',
}

presentation   = {} #Sunum bilgileri sözlüğü
tag            = {} #Etiket bilgileri sözlüğü

class File #File sınıfı
  @@absolute_path_here = Pathname.new(Pathname.pwd) #File sınıfında path_here isimli bir sınıf metodumuz var ve @@absolute_path_here sınıf değişkeni  bir statik değişken

  def self.to_herepath(path) #Self ile herepath adında sınıf metodu tanımlanmış
    Pathname.new(File.expand_path(path)).relative_path_from(@@absolute_path_here).to_s #Yeni bir nesne üretiliyor ve relative_path_form ile argüman alıcıya göreceli bir yol döner. 
  end
  def self.to_filelist(path) #Self ile herepath adında sınıf metodu tanımlanmış
    File.directory?(path) ?  #Adlı dosya bir dizin ise doğru döndürür
      FileList[File.join(path, '*')].select { |f| File.file?(f) } :
      [path]
  end
end

def png_comment(file, string) #PNG standart izin veren herhangi bir görüntü çözer.
  require 'chunky_png' #Bu kütüphane, PNG dosyalarını okuma ve yazmak içindir.
  require 'oily_png'

  image = ChunkyPNG::Image.from_file(file) #Dosya nesnesi geçici yüklendiği dizinde görüntünün yerini tutar.
  image.metadata['Comment'] = 'raked'
  image.save(file) #Dosyayı kaydetme
end

def png_optim(file, threshold=40000)
  return if File.new(file).size < threshold
  sh "pngnq -f -e .png-nq #{file}"#boyut düzeltmesi yapma
  out = "#{file}-nq"
  if File.exist?(out) #FileTest bir dosya bekliyormu görmek için bir onay ile birleştirilmesi gerekiyor.
    $?.success? ? File.rename(out, file) : File.delete(out)
  end
  png_comment(file, 'raked')
end

def jpg_optim(file)
  sh "jpegoptim -q -m80 #{file}"
  sh "mogrify -comment 'raked' #{file}"
end

def optim
  pngs, jpgs = FileList["**/*.png"], FileList["**/*.jpg", "**/*.jpeg"]# jpeg resimler ve png resimler

  [pngs, jpgs].each do |a| #Boyut düzeltmesi
    a.reject! { |f| %x{identify -format '%c' #{f}} =~ /[Rr]aked/ }
  end

  (pngs + jpgs).each do |f| #İki dizini birleştir ve üzerinde dolaş
    w, h = %x{identify -format '%[fx:w] %[fx:h]' #{f}}.split.map { |e| e.to_i }
    size, i = [w, h].each_with_index.max #Listedeki en büyük elemanın indeksini al
    if size > IMAGE_GEOMETRY[i] #resim boyutları sizedan küçük ise
      arg = (i > 0 ? 'x' : '') + IMAGE_GEOMETRY[i].to_s #i sıfırdan büyük ise x koyup string'e çevir
      sh "mogrify -resize #{arg} #{f}" #Görüntüde yapılan değişikliği f olarak kaydet
    end
  end

  pngs.each { |f| png_optim(f) } #pngs de dolaş optim f olara
  jpgs.each { |f| jpg_optim(f) } #jpgs de dolaş optim f olara

  (pngs + jpgs).each do |f|
    name = File.basename f
    FileList["*/*.md"].each do |src| #Sadece alt dizinlerdeki markdown dosyalar
      sh "grep -q '(.*#{name})' #{src} && touch #{src}"
    end
  end
end

default_conffile = File.expand_path(DEFAULT_CONFFILE)

FileList[File.join(PRESENTATION_DIR, "[^_.]*")].each do |dir|
  next unless File.directory?(dir)
  chdir dir do
    name = File.basename(dir)
    conffile = File.exists?('presentation.cfg') ? 'presentation.cfg' : default_conffile
    config = File.open(conffile, "r") do |f|
      PythonConfig::ConfigParser.new(f)
    end

    landslide = config['landslide']
    if ! landslide#landslide tanımlanmamışsa
      $stderr.puts "#{dir}: 'landslide' bölümü tanımlanmamış"#Ekrana hata mesajını bas
      exit 1
    end

    if landslide['destination'] #destination ayarı
      $stderr.puts "#{dir}: 'destination' ayarı kullanılmış; hedef dosya belirtilmeyin" #Destination ayarı kullanılmışsa ekrana hata mesajını bas
      exit 1
    end

    if File.exists?('index.md')#index.md dosyaları varsa 
      base = 'index' #base e index ata
      ispublic = true #ispublice true ata
    elsif File.exists?('presentation.md')#presentation.md dosyaları varsa 
      base = 'presentation'#base e presantetion ata
      ispublic = false#ispublice false ata
    else
      $stderr.puts "#{dir}: sunum kaynağı 'presentation.md' veya 'index.md' olmalı"# her ikiside yoksa ekrana hata mesajı bastır
      exit 1
    end

    basename = base + '.html'
    thumbnail = File.to_herepath(base + '.png')
    target = File.to_herepath(basename)

    deps = []
    (DEPEND_ALWAYS + landslide.values_at(*DEPEND_KEYS)).compact.each do |v|
      deps += v.split.select { |p| File.exists?(p) }.map { |p| File.to_filelist(p) }.flatten
    end

    deps.map! { |e| File.to_herepath(e) }#kontrol et
    deps.delete(target)#target siliniyor
    deps.delete(thumbnail)#thumbnail siliniyor

    tags = []

   presentation[dir] = {
      :basename  => basename,	# üreteceğimiz sunum dosyasının baz adı
      :conffile  => conffile,	# landslide konfigürasyonu (mutlak dosya yolu)
      :deps      => deps,	# sunum bağımlılıkları
      :directory => dir,	# sunum dizini (tepe dizine göreli)
      :name      => name,	# sunum ismi
      :public    => ispublic,	# sunum dışarı açık mı
      :tags      => tags,	# sunum etiketleri
      :target    => target,	# üreteceğimiz sunum dosyası (tepe dizine göreli)
      :thumbnail => thumbnail, 	# sunum için küçük resim
    }
  end
end

presentation.each do |k, v| #presantation sözlüğündeki keyler k ye valuelar v ye atılıyor
  v[:tags].each do |t|
    tag[t] ||= []
    tag[t] << k
  end
end

tasktab = Hash[*TASKS.map { |k, v| [k, { :desc => v, :tasks => [] }] }.flatten]

presentation.each do |presentation, data|# keyleri presentation a atıyor valueları data ya atıyor
  ns = namespace presentation do #presentation ı çalışma uzayına atıyor
    file data[:target] => data[:deps] do |t|
      chdir presentation do#presentation a geç 
        sh "landslide -i #{data[:conffile]}"
        sh 'sed -i -e "s/^\([[:blank:]]*var hiddenContext = \)false\(;[[:blank:]]*$\)/\1true\2/" presentation.html'#html de yeni bir sayfa açılır
        unless data[:basename] == 'presentation.html'#basename presentation.html değil ise  
          mv 'presentation.html', data[:basename]
        end
      end
    end

    file data[:thumbnail] => data[:target] do
      next unless data[:public]
      sh "cutycapt " +
          "--url=file://#{File.absolute_path(data[:target])}#slide1 " +
          "--out=#{data[:thumbnail]} " +
          "--user-style-string='div.slides { width: 900px; overflow: hidden; }' " +
          "--min-width=1024 " +
          "--min-height=768 " +
          "--delay=1000"
      sh "mogrify -resize 240 #{data[:thumbnail]}"
      png_optim(data[:thumbnail])
    end

    task :optim do
      chdir presentation do
        optim
      end
    end

    task :index => data[:thumbnail]

    task :build => [:optim, data[:target], :index]

    task :view do
      if File.exists?(data[:target]) #datanın içinde target value lu key aranıyor
        sh "touch #{data[:directory]}; #{browse_command data[:target]}"#varsa gekli dosyalar oluşturuluyor
      else
        $stderr.puts "#{data[:target]} bulunamadı; önce inşa edin" #yoksa ekrana hata mesajını bas
      end
    end

    task :run => [:build, :view]

    task :clean do #target ve thumbnail i temizle
      rm_f data[:target]
      rm_f data[:thumbnail]
    end

    task :default => :build #buildi çalıştır
  end

  ns.tasks.map(&:to_s).each do |t| #ns nin taskına haritalama yap ve üzerinde dolaş
    _, _, name = t.partition(":").map(&:to_sym)
    next unless tasktab[name]
    tasktab[name][:tasks] << t
  end
end

namespace :p do #görev adlarının tutulacağı yerler
  tasktab.each do |name, info| #tasktab ın keyleri name e valueları info ya atılır
    desc info[:desc]
    task name => info[:tasks]
    task name[0] => name
  end

  task :build do #buildi oluşturr
    index = YAML.load_file(INDEX_FILE) || {}
    presentations = presentation.values.select { |v| v[:public] }.map { |v| v[:directory] }.sort #presantationın değerleri public ve directory olarak sıralanıyor
    unless index and presentations == index['presentations']
      index['presentations'] = presentations
      File.open(INDEX_FILE, 'w') do |f|
        f.write(index.to_yaml)
        f.write("---\n")
      end
    end
  end

  desc "sunum menüsü"
  task :menu do
    lookup = Hash[ #çırpı tablosu
      *presentation.sort_by do |k, v|#presantation sözlüğündeki keyler k ye valuelar v ye atılıyor
        File.mtime(v[:directory])#presenatation dizilerini tarihine göre sırala
      end
      .reverse #ters çevir
      .map { |k, v| [v[:name], k] }#valuenun adını yaz keyini al
      .flatten #dizgi içindeki dizgileri tek dizgi haline getir
    ]
    name = choose do |menu|
      menu.default = "1" #defult 1
      menu.prompt = color( #prompt un rengi
        'Lütfen sunum seçin ', :headline
      ) + '[' + color("#{menu.default}", :special) + ']'
      menu.choices(*lookup.keys)
    end
    directory = lookup[name]
    Rake::Task["#{directory}:run"].invoke
  end
  task :m => :menu
end

desc "sunum menüsü" #açıklama
task :p => ["p:menu"]
task :presentation => :p
