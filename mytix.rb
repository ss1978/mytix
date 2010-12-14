#!/usr/bin/env ruby 


# == Synopsis 
# MyTix: A file based ticketing "system".
# 
# The program aimed to be easily installable (copying one file)
# 
# 
# == Features
# * Ticket data stored in yaml files
# * Customizable severity, status
# * Colorised Console output
# * GUI (FXRuby)
# * Customizable trigger after creating a ticket, adding attachment.
# * Comments
# * Attachments
# 
# == Requirements
# * FXRuby (1.6)
# 
# == Getting started
# 0. Copy the script into the $PATH (eg: <tt>/usr/local/bin</tt>)
# 1. Initialize the environment:
#     mytix init
# 2. Edit the <tt>.mytix.yaml</tt> file as required.
# 3. Add a ticket with:
#     mytix add "Issue #1"
#    You can use the gui either (with optional ticket naming):
#     mytix gadd {"Issue #1"}
#    
# 4. List tickets:
#     mytix list
# 5. Change status of the ticket (if the ticket's id is 12345678):
#     mytix status 12345678 closed
# 
# == Usage 
# mytix [command] [arguments]
#
# For help use: 
# 	mytix -h
# or 
# 	mytix --help
# For version info:
# 	mytix -v
# or 
#	mytix --version
# Commands are:
# [init						]
# 	Initializes the mytix environment
# [list	{status/tag}*n {+-{property}}		]
# 	Lists the tickets with status or tag with the supplied order.
# 	+/-{property} tells the ordering, other parameters defines filtering
# [add <TICKET_NAME>				]
# 	Adds a ticket to the database
# [show <TICKET_ID>				]
# 	Shows the tickets from the database
# [attach <TICKET_ID> ({MESSAGE} <FILENAME>)*n	]
#   Adds attachment with name to the ticket.
# [status <TICKET_ID> <STATUS>			]
# 	Sets status for the ticket.
# [comment <TICKET_ID> <COMMENT>			]
# 	Adds comment for the ticket.
# [gadd {TICKET NAME}				]
# 	Adds a ticket to the database using GUI
# [glist						]
# 	Lists the tickets using gui.
# [gedit <TICKET_ID>				]
# 	Edits the selected ticket.
#
#
# == Author
# Sipos Sándor <ss1978@lajt.hu>
#
# == Copyright
# Copyright (c) 2010 Sipos Sándor. Licensed under the GPL3 License:
# http://www.gnu.org/licenses/gpl.html


require 'etc' 
require 'rdoc/usage'
require 'ostruct'
require 'date'
require 'ftools'
require 'yaml'
require 'yaml/encoding'
require 'digest/md5'
require 'pathname'

$fox=true
#Do not require fox if not necessary.
ARGV.each do | i | 
	if ["init", "list", "status", "add", "comment", "attach", "show"].include?( i ) then 
		$fox=false 
	end
end

if $fox
	begin 
		$fox = require 'fox16'
		if $fox
			include Fox
		end
	rescue LoadError
		$fox = false
	end
end

################################################################################
#
# UTF-8 hack.
#
################################################################################
# Our String extension, to support utf-8 at a minimal level
class String
	
	#Returns the utf8 (character, not byte) length
	def length_utf8
		count = 0 
		scan(/./mu) { count += 1 } 
		count 
	end

end

################################################################################
#
# Console output
#
################################################################################

# Console module.
module Console

	#Prints out the s in the ANSI color.
	def colorize( s, color )
		if color
			return "#{color}#{s}\033[0m"
		else
			return "#{s}"
		end
	end
	
	#Class for printing out list in tabular and colorized form.
	class Tabular < Array 
	
		#Represents a row in the table. Internal use only
		class Row # :nodoc:
	
			#Columns in the row.
			attr_reader :cols

			def initialize( color, cols )
				@color = color
				@cols = cols
			end
	
			#Prints out the row data.
			def p( colsizes, align = nil, padding = 3 )
				print "#{@color}"
				idx = 0
				@cols.each do |item|
					if align and align[idx] == "r"
						print " " * (  colsizes[ idx ] - item.to_s.length_utf8  )
					end
					print item
					if align==nil or (align and align[idx] == "l")
						print " " * (  colsizes[ idx ] - item.to_s.length_utf8  )
					end
					print " "*padding if idx < colsizes.length - 1
					idx += 1
				end
				puts "\033[0m"
			end
	
		end
	
		# Creates the Tabular, with the (optional) header (array of strings).
		def initialize( header = nil, alignarray=nil, padding=3 )
			@colsizes=[]
			@align = alignarray
			@padding = padding

			if header
				self<<( {"cols"=>header, "color"=>"\e[4m"} )
			end
		end
	
		# Adds a row to the table, the item should be a mapping with "color" and "cols" data.
		def <<(item)
			row = Row.new( item["color"], item["cols"] )
			super( row )
	
			curcolsizes = item["cols"].map do |col|			
				col ? col.to_s.length_utf8 : 0
			end
			
			(curcolsizes.length-@colsizes.length).times do
				@colsizes << 0
			end
	
			curcolsizes.length.times do |idx|
				curs = curcolsizes[idx]
				@colsizes[idx] = curs if @colsizes[idx] < curs
			end
		end
		
		# Prints out the table, with the header.
		def print
			self.each do |item|
				item.p( @colsizes, @align, @padding )
			end
		end

	end
end

################################################################################
#
# BOM
#
################################################################################

# Represents the Object Model of the "application"
module BOM

	# Represents an Attachment, which belongs to a Ticket
	class TicketAttachment
		#The attachment creation date.
		attr_accessor :created
		#The Comment for the attachment ticket.
		attr_accessor :comment
		#The attachment creator.
		attr_accessor :created_by
		#The Filename
		attr_reader :original_name
		#The stored name
		attr_accessor :name
		#The id of the file
		attr_accessor :fileid

		# Creates an attachment.
		# [ticket]
		#	a Ticket object
		# [comment]
		#	the comment for the attachment
		# [original_n]
		# 	The original name of the attachment
		def initialize( ticket, comment, original_n, user = nil )
			@created = DateTime.now()
			@ticket = ticket
			@comment = comment
			@created_by = user == nil ? Etc.getlogin() : user
			self.original_name = original_n
		end

		#Sets te original_name property
		def original_name=(value)
			@original_name = File.basename( value )
			@fileid	= Digest::MD5::hexdigest("#{@comment}-#{@original_name}-#{@created}")[0..7]
			name = File.join( "attachments", @fileid, @original_name )
			
			puts "Attaching #{original_name} file with comment: \"#{comment}\" and id #{fileid} #{@ticket.filename}"
			dir = File.dirname( @ticket.filename ) 
			Dir.mkdir( dir ) if not File.directory?( dir )

			attDir =  File.join( dir, "attachments")
			Dir.mkdir( attDir ) if not File.directory?( attDir ) 
			fileAttDir = File.join( attDir, @fileid )
			Dir.mkdir( fileAttDir ) if not File.directory?(  fileAttDir )
			File.copy( value, fileAttDir )
		end

		def to_yaml_properties # :nodoc:
			["@comment", "@original_name", "@created", "@created_by","@fileid" ]
		end
	end

	# Represents a Comment, which belongs to a Ticket
	class TicketComment

		#The comment itself
		attr_reader :comment
		#The creation timestamp.
		attr_reader :created
		#The comment's creator
		attr_reader :created_by
	
		#Creates a Comment object, by default as a running user.
		def initialize( text, user = nil )
			@comment = text
			@created = DateTime.now()
			@created_by = user == nil ? Etc.getlogin() : user
		end
	
	end

	#Represents the persistable part of the Ticket
	class TicketData

		#The ticket's name (eg: Error during adding this and that)
		attr_accessor :name 
		
		#The creation date
		attr_accessor :created 
		
		#The modification date
		attr_accessor :updated 
		
		#The ticket creator's name
		attr_accessor :created_by 
		
		#The ticket's detailed description.
		attr_accessor :description 
		
		#The tags assigned to the Ticket.
		attr_accessor :tags 
	
		#The severity of the ticket
		attr_accessor :severity 
		
		#The modules' name, the Ticket belongs to.
		attr_accessor :modules 
		
		#The status of the ticket.
		attr_accessor :status
	
		# Creates the TicketData. 
		#
		# Defaults:
		#
		# [created] Current timestamp
		# [created_by] Current logged in user (login name)
		# [updated] Current timestamp
		# [severity] The first entry of severity definitions in the .mytix.yaml
		# [status] The first entry of severity definitions in the .mytix.yaml
		def initialize( options, name )
			@name = name.gsub(/[\r\n]/, '')
			@created = DateTime.now()
			@updated = DateTime.now()
			@created_by = Etc.getlogin()
			@description = ""
			@tags = []
			@severity = options.severity[0]
			@modules = []
			@status = options.status[0]
		end

	end 

	#The Ticket handling class
	class Ticket < Object
	
		#The TicketData
		attr_accessor :data
		#The yaml file to save the data
		attr_reader :filename
		#The 8 character long id (first 8 characters of the ticket.yaml's directory
		attr_reader :idstring
		#The comments' list (contains TicketComment)
		attr_reader :comments
		#The attachments' list (contains TicketAttachment)
		attr_reader :attachments
	
		def initialize( options, name )
			@data = TicketData.new( options, name )
			@options = options
			@filename = nil 
			@idstring = nil
			@comments = []
			@attachments = []
		end
	
		# Specifies the filename to use (either the id of the Ticket)
		def filename=( value )
			@filename = value
			@idstring = File.basename( File.dirname( filename ) )[0..7]
		end
	
		# Stringify.
		def to_s()
			"#{@idstring} #{@data.name} #{data.status}(#{@data.severity})  #{@data.created}"
		end

		# Loads Comments, from the comments.yaml file
		def loadComments( )
			if @filename
				commentsFile = File.join( File.dirname( @filename ), "comments.yaml" )
				if File.file?( commentsFile )
					@comments = YAML.load_file( commentsFile ) 
				end 
			end
		end

		# Loads Attachments, from the attachments.yaml file
		def loadAttachments( )
			if @filename
				attachmentsFile = File.join( File.dirname( @filename ), "attachments.yaml" )
				if File.file?( attachmentsFile )
					@attachments = YAML.load_file( attachmentsFile ) 
				end 
			end
		end

		#Loads ticket's data from the specified directory. 
		def load( dirname )
			@filename= File.join( dirname, "ticket.yaml" )
			@idstring = File.basename( dirname )[0..7]
			if File.file?( @filename )
				@data = YAML.load_file( @filename ) 
			end 
			loadComments
			loadAttachments
		end

		#Sets status to requested, if it's in the .mytix.yaml/status array
		def setStatus( status )
			if @options.status.include?( status )
				@data.status = status
				return true
			end
			false
		end
	
		#Appends a comment to the Ticket
		def addComment( text )
			loadComments if @comments.length == 0
			@comments.push( TicketComment.new( text ) )
		end

		#Appends attachments to the Ticket
		def addAttachments( attData )
			loadAttachments if @attachments.length == 0
			comment = ""
			attData.each do |item|
				puts item
				if File.file?( item )
					@attachments.push( TicketAttachment.new( self, comment, item ) )
				else
					comment = item
				end
			end
		end
		
		#Saves ticket, and comment data.
		#Creates the required directories if missing.
		def save( )
			destDir = nil		
			add = false
			if not @filename
				created = Digest::MD5::hexdigest("#{@data.created}-#{@data.name}")
				created = created[ 0, 8 ]
				name = @data.name.gsub( /[\/\\\ :\?]/, '_')
				Dir.mkdir( @options.tickets_directory ) if not File.directory?( @options.tickets_directory )
				destDir =  File.join( @options.tickets_directory, "#{created}-#{name}.ticket")
				if not File.directory?( destDir )
					Dir.mkdir( destDir )
					add = true
				end
				@data.updated=DateTime.now()
				@idstring = File.basename( destDir )[0..7]
				@filename =  File.join( destDir, "ticket.yaml")
			end
	
			
			File.open( @filename, File::WRONLY|File::TRUNC|File::CREAT) do |f|
				f.write YAML.unescape( YAML.dump( @data ) )
			end
	
			loadComments if @comments.length == 0
			commentsFile = File.join( File.dirname(@filename) , "comments.yaml" ) 
			File.open( commentsFile, File::WRONLY|File::TRUNC|File::CREAT) do |f|
				f.write YAML.unescape( YAML.dump( @comments ) )
			end
			
			loadAttachments if @attachments.length == 0
			attachmentsFile = File.join( File.dirname(@filename) , "attachments.yaml" ) 
			File.open( attachmentsFile, File::WRONLY|File::TRUNC|File::CREAT) do |f|
				f.write YAML.unescape( YAML.dump( @attachments ) )
			end
			
			if add
				cmd = @options.after_add_ticket
				if cmd and not cmd.empty?
					system( "#{cmd} \"#{destDir}\"" )
				end
			end
			puts "Ticket #{@idstring} saved."
		end
	end
end 

#Class for query/cache ticket informations
#
#TODO: cache should be expired immediately after ticket change. Currently it costs to seconds.
class TicketHandler
	attr_reader :ready_to_run

	#Constructor.
	def initialize( options )
		@options = options 
		@cache = Array.new()
		@cache_for_id = {}
		@cache_for_name = {}
		@ready_to_run = false
		if @options and @options.cache_directory 
			Dir.mkdir( @options.cache_directory ) if not File.directory?(  @options.cache_directory  )
			@ready_to_run = true
			rebuildCache
		else
			puts "MyTix environment not initialized."
			puts "Please run \"mytix init\" first!"
		end
	end

	#Updates cache entries for the provided ticket
	def rebuildCacheFor( ticket )
		pos = @cache_for_id[ ticket.idstring ]
		if pos 
			@cache[ pos ] = ticket
			@updated = true
			save
		else 
			rebuildCache
		end
	end

	#Scans filesystem for cache changes, and rebuilds the cache if it's needed.
	def rebuildCache
		
		@cache = Array.new()
		@cache_for_id = {}
		@cache_for_name = {}

		cache_file = File.join( @options.cache_directory, "tickets.yaml" ) 
		if File.file? cache_file
			c = YAML.load_file( cache_file )
			if c
				c["cache"].each do |v|
					t = BOM::Ticket.new( @options, "" )
					t.data = v[ "ticket" ]
					t.filename = v[ "file" ]
					@cache.push( t )
				end
				@cache_for_id = c["cache_for_id"]
				@cache_for_name = c["cache_for_name"]
			end
		end

		@updated = false
		
		removeitems = []

		@cache_for_name.each do | k, v |
			if not File.directory?( File.join( @options.tickets_directory, k ) )
				@cache_for_name.delete( k )
				@cache_for_id.delete( k[0..7] )
				removeitems << v["idx"]
			end 
		end

		if removeitems.length > 0
			@updated = true
		end

		removeitems.sort.reverse_each do |i|
			@cache.delete_at( i )
		end


		Dir.glob( File.join( @options.tickets_directory, "*" ) ) do |f| 
			bf = File.basename( f )
			mtime = File.mtime( f )  
			if @cache_for_name.include?( bf )
				ticket_update_info = @cache_for_name[ bf ]
				idx = ticket_update_info[ "idx" ]
				if mtime>ticket_update_info[ "updated" ]
					u = ticket_update_info["updated"]
					t = BOM::Ticket.new( @options, "" )
					t.load( f )
					@cache[ idx ] = t
					@cache_for_name[ bf ] = {"idx"=>idx, "updated"=> mtime}
					@updated = true
				end
			else
				t = BOM::Ticket.new( @options, "" )
				t.load( f )
				@cache.push( t )
				@cache_for_id[ bf[0..7] ] = @cache.length-1
				@cache_for_name[ bf ] = {"idx"=>@cache.length-1, "updated"=> mtime}
				@updated = true
			end
		end
		save
	end

	#Saves cache data.
	def save
		if @updated
			File.open( File.join( @options.cache_directory, "tickets.yaml" ), File::WRONLY|File::TRUNC|File::CREAT) do |f|
				mycache = Array.new
				@cache.each do |i|
					mycache.push( {"file"=>i.filename, "ticket"=> i.data } )
				end
				YAML.dump( { "cache"=> mycache, "cache_for_id" => @cache_for_id, "cache_for_name" => @cache_for_name }, f )
			end
		end
	end

	#Sorts, filters tickets.
	#When a string begins with +/- character: will define sorting, otherwise filtering.
	def each( args )
		sortby = args.select{ |v| v =~ /^[\+\-].*$/ }
		filters = args-sortby
		statuses = filters.select{ |i| @options.status.include?( i ) }
		#statuses = filters.select{ |i| @tags.include?( i ) }
		if statuses.length > 0
			filtered = @cache.select{ |i| statuses.include?( i.data.status ) }
		else
			filtered = @cache
		end
		sorted = filtered
		if sortby.length > 0
			sort = sortby[0][1, 100]
			dir = '+'==sortby[0][0,1] ? 1 : -1
			puts "#{dir} #{sort} #{sortby[0][0]}"
			sorted = filtered.sort{ |a,b| dir * (a.data.send( sort )<=> b.data.send( sort )) } 
		end
		sorted.each do |i|
			yield( i )
		end
	end

	#Returns the tickets in the cache.
	def length 
		@cache.length
	end

	#Filters tickets by it's id.
	def filter_by_id( id )
		if @cache_for_id.include?( id )
			yield( @cache[@cache_for_id[ id ]] )
			@updated = true
		else
			ret = Array.new()
			@cache_for_id.each_pair do |k,v|
				if k.index( id ) == 0
					yield( @cache[ v ] )
					@updated = true
				end
			end
		end
		save
	end
end

if $fox
################################################################################
#
#	GUI classes
# 
################################################################################
module GUI

	class ClickableVerticalFrame <  FXVerticalFrame
	
		def canFocus?
			return true
		end

	end

	#The base of Ticket Editing windows.
	module TicketEditWindowBase 

		#Creates the GUI layout.
		def creategui( app, close, t )		
			
			@ticket = t ? t : BOM::Ticket.new( app.options, "" )
			@name = FXDataTarget.new( @ticket.data.name )
			@description = FXDataTarget.new( @ticket.data.description )
			@status = FXDataTarget.new( @ticket.data.status )
			@severity = FXDataTarget.new( @ticket.data.severity )
			
			f = FXVerticalFrame.new( self, LAYOUT_FILL_X | LAYOUT_FILL_Y )
			
			m = FXMatrix.new( f, 2, LAYOUT_FILL_X |MATRIX_BY_COLUMNS )
			
			FXLabel.new( m, "Name")
			FXTextField.new( m, 2, @name, FXDataTarget::ID_VALUE,  LAYOUT_FILL_X |FRAME_THICK | FRAME_SUNKEN | LAYOUT_FILL_COLUMN )
	
			FXLabel.new( m, "Description")
			FXText.new( FXVerticalFrame.new( m, LAYOUT_FILL_X|LAYOUT_FILL_Y|LAYOUT_FILL_COLUMN|FRAME_SUNKEN|FRAME_THICK, 0,0,0,0, 0,0,0,0, 0,0 ), @description, FXDataTarget::ID_VALUE,  LAYOUT_FILL_X |FRAME_THICK | FRAME_SUNKEN | LAYOUT_FILL_Y | LAYOUT_FILL_COLUMN )
	
			FXLabel.new( m, "Status" )
			statusC = FXComboBox.new( m, 5, @status, FXDataTarget::ID_VALUE, LAYOUT_FILL_COLUMN|LAYOUT_FILL_X | COMBOBOX_STATIC | FRAME_SUNKEN | FRAME_THICK ) 
			app.options.status.each { |i| statusC.appendItem( i ) }
			statusC.numVisible = app.options.status.length
	
			FXLabel.new( m, "Severity" )
			severityC = FXComboBox.new( m, 5, @severity, FXDataTarget::ID_VALUE, LAYOUT_FILL_COLUMN|LAYOUT_FILL_X | COMBOBOX_STATIC | FRAME_SUNKEN | FRAME_THICK ) 
			app.options.severity.each { |i| severityC.appendItem( i ) }
			severityC.numVisible = app.options.severity.length
	
			gbc = FXGroupBox.new(f, "Comments",  LAYOUT_FILL_X|LAYOUT_FILL_Y|FRAME_GROOVE )
			gbcc= FXVerticalFrame.new(gbc, LAYOUT_FILL_X|LAYOUT_FILL_Y, :padding=>0)
			tb = FXHorizontalFrame.new(gbcc, LAYOUT_FILL_X, :padding=>0)
	
			FXButton.new( tb, "New",  getApp().icons.find("16x16/actions/filenew.png"), :opts=>BUTTON_TOOLBAR|FRAME_RAISED|ICON_BEFORE_TEXT ).connect( SEL_COMMAND, method( :onNewComment ) )
			scrollwindowB = FXVerticalFrame.new(gbcc, LAYOUT_FILL_X|LAYOUT_FILL_Y|FRAME_SUNKEN|FRAME_THICK, :padding=>0)
			scrollwindow = FXScrollWindow.new(scrollwindowB, LAYOUT_FILL_X|LAYOUT_FILL_Y)
			scrollwindow.backColor = getApp().baseColor
			@commentListF = ClickableVerticalFrame.new( scrollwindow, :opts=>LAYOUT_FILL_X, :padding=>2 )
			@commentListF.backColor = FXRGB(127,127,127)
	
			@commentpopup = FXMenuPane.new( self )
	
			FXMenuCommand.new( @commentpopup, "New Comment", getApp().icons.find("16x16/actions/filenew.png") ).connect( SEL_COMMAND, method( :onNewComment ) )
	
			@commentListF.connect( SEL_RIGHTBUTTONRELEASE ) do | obj, sel, par |
				@commentpopup.create
				@commentpopup.popup( nil, par.root_x, par.root_y )
			end
		
			@ticket.loadComments
			
			bf = FXVerticalFrame.new( f, LAYOUT_BOTTOM|LAYOUT_FILL_X )
			FXHorizontalSeparator.new( bf )
			b = FXHorizontalFrame.new( bf, LAYOUT_SIDE_RIGHT|LAYOUT_FILL_X )
			okb = FXButton.new( b, "Ok", nil, self, 0, LAYOUT_RIGHT | BUTTON_NORMAL , 0, 0, 0, 0, 5, 5  )
			
			okb.connect( SEL_COMMAND ) do |sender, sel, param|
				@ticket.data.name = @name.value
				@ticket.data.description = @description.value
				@ticket.data.status = @status.value
				@ticket.data.severity = @severity.value
				@ticket.save
				getApp().handler.rebuildCacheFor( @ticket )
				self.onCmdClose
			end
	
			FXButton.new( b, "Cancel", nil, self, close, LAYOUT_RIGHT | BUTTON_NORMAL , 0, 0, 0, 0, 5, 5 ).connect( SEL_COMMAND, method( :onCmdClose ) )
		end
	
		#After creating the window, populates the Commentlist
		def create
			super
			printComments
		end
	
		#Rebuilds commentlist.
		def printComments
			@commentListF.children.each { |c| @commentListF.removeChild( c ) }
	
			@ticket.comments.each do | comment |
				btnf = FXVerticalFrame.new( @commentListF, :opts=>LAYOUT_FILL_X|FRAME_LINE, :padding=>2 )
				btnf.create
				btn = FXToggleButton.new(btnf, "#{comment.created_by} @ #{comment.created}" ,"#{comment.created_by} @#{comment.created}" , :opts => LAYOUT_FILL_X|BUTTON_NORMAL|JUSTIFY_LEFT|TOGGLEBUTTON_KEEPSTATE )
				btn.connect(SEL_COMMAND) do | obj, sel, par |
					obj.next.handle( self, FXSEL( SEL_COMMAND, FXWindow::ID_TOGGLESHOWN), nil )
				end
				#btn.state= true
				btn.tipText =  "#{comment.comment}"
				btn.create
				( lbl = FXLabel.new( btnf, "#{comment.comment}", :opts => LAYOUT_FILL_X|JUSTIFY_LEFT ) ).hide
				lbl.create
			end
		end
	
		#Action for creating new comment	
		def onNewComment( obj, sel, par )
			d = FXDataTarget.new( "" )
			win = FXDialogBox.new( getApp(), "Comment edit", DECOR_ALL )
			f = FXVerticalFrame.new( win, LAYOUT_FILL_Y|LAYOUT_FILL_X )
			text = FXText.new( f, d, FXDataTarget::ID_VALUE, :opts=>LAYOUT_FILL_X|LAYOUT_FILL_Y )
			FXHorizontalSeparator.new( f )
			bf = FXHorizontalFrame.new( f, LAYOUT_FILL_X )
			FXButton.new( bf, "Ok", nil, win, FXDialogBox::ID_ACCEPT, LAYOUT_RIGHT|FRAME_THICK|FRAME_RAISED )
			FXButton.new( bf, "Cancel", nil, win, FXDialogBox::ID_CLOSE, LAYOUT_RIGHT|FRAME_THICK|FRAME_RAISED )
	
			if win.execute()
				@ticket.addComment( d.value )
				printComments
				@commentListF.update
			end
			return 1
		end 
	
	end

	#The Dialog representation of the Ticket Edit window
	class TicketEditDialog < FXDialogBox

		include TicketEditWindowBase
	
		def initialize( app, task = nil )
			super( app, "Ticket", :opts => DECOR_ALL, :width=>640, :height=>400 )
			creategui( app, ID_CLOSE, task )
		end

		def onCmdClose( a=nil, b=nil, c=nil )
			close
		end
	
	end
	
	#The MDIChild representation of the Ticket Edit window
	class TicketEditWindow < FXMDIChild
		
		include TicketEditWindowBase
		
		def initialize( app, mdimenu, mdiclient, task = nil, icon=nil  )
			super( mdiclient, "Ticket", icon, mdimenu, 0, mdiclient.numChildren*20, mdiclient.numChildren*20, 640, 480 )
			creategui( app, ID_MDI_CLOSE, task )
		end
	
		def onCmdClose( a=nil, b=nil, c=nil )
			self.close
		end
	
	end
	
	#Colorized Item for FXIconList
	class ColorizedIconItem < FXIconItem

		DETAIL_TEXT_SPACING = 2
		SIDE_SPACING = 2

		#The constructor of ColorizedIconItem.
		def initialize( text, icon1, icon2, color, data )
			super( text, icon1, icon2, data )
			@color = color
		end
	
		#Overridden method of FXIconItem's drawDetails, for using different colors for each item.
		# TODO: implement usage of icons.
		def drawDetails( list, dc2, x, y, w, h )
			FXDCWindow.new( list ) do |dc|
				header = list.header
				font = list.font
				dc.font = font
				iw=0;ih=0;tw=0;th=0
				return if header.numItems==0
			
				if selected?
					dc.setForeground( list.selBackColor )
					dc.fillRectangle( x, y, header.totalSize,h)
				end
				
				dc.drawFocusRectangle(x+1,y+1,header.totalSize-2,h-2) if hasFocus?
				xx=x+SIDE_SPACING/2
				
				if miniIcon
					iw=miniIcon.width
					ih=miniIcon.height
					dc.setClipRectangle(x,y,header.getItemSize(0),h)
					dc.drawIcon(miniIcon,xx,y+(h-ih)/2)
					dc.clearClipRectangle()
					xx+=iw+DETAIL_TEXT_SPACING;
				end
  				
				if not text.empty?
					th=font.fontHeight
					dw=font.getTextWidth("...")
					yt=y+(h-th-4)/2
				
					if not enabled?
						dc.setForeground(makeShadowColor(list.backColor))
					elsif selected?
						dc.setForeground(list.selTextColor)
					else
						color = list.textColor
						color = FXRGB( @color[1..2].to_i(16), @color[3..4].to_i(16),@color[5..6].to_i(16) ) if not @color.empty?
						dc.setForeground( color )
					end
					
					used=iw+DETAIL_TEXT_SPACING+SIDE_SPACING/2
   	 			
					i = 0
					text.split("\t").each do | t |
						if i<header.numItems
							dc.clipRectangle=FXRectangle.new(header.getItemOffset(i ), yt, header.getItemSize(i), font.fontAscent + 4 )
   		       				dc.drawText( xx + tw + 2 + header.getItemOffset( i ), yt + font.fontAscent + 2, t )
							dc.clearClipRectangle
						end
						i+=1
					end
					dc.end
				end

			end
		end

	end

	#Base of ticket listing windows.
	module TicketListWindowBase 
	
		#Specifies Listing window's layout.
		def creategui( app, close, list )		
			@filter = FXDataTarget.new( "" )
			f = FXVerticalFrame.new( self, LAYOUT_FILL_X | LAYOUT_FILL_Y )
			
			f2 = FXHorizontalFrame.new( f, LAYOUT_FILL_X )		
			FXLabel.new( f2, "Filter")
			FXTextField.new( f2, 2, @filter, FXDataTarget::ID_VALUE,  LAYOUT_FILL_X |FRAME_THICK | FRAME_SUNKEN | LAYOUT_FILL_COLUMN)
			f3 = FXHorizontalFrame.new( f, LAYOUT_FILL_X|LAYOUT_FILL_Y|FRAME_SUNKEN|FRAME_THICK , :padding=>0 )		
			@iconlist = FXIconList.new(f3, :opts=>LAYOUT_FILL_X|LAYOUT_FILL_Y|ICONLIST_DETAILED )
			@iconlist.appendHeader("Name", nil, 200)
			@iconlist.appendHeader("Severity", nil, 100)
			@iconlist.appendHeader("Status", nil, 60)
			@iconlist.appendHeader("Created", nil, 150)
			@iconlist.appendHeader("Modified", nil, 150)
			@iconlist.appendHeader("User", nil, 50)
	
			@iconlistmenu = FXMenuPane.new( self )
			FXMenuCommand.new( @iconlistmenu, "&New\tCtrl+N\tNew ticket", getApp().icons.find( "16x16/actions/filenew.png" ) ).connect( SEL_COMMAND ) do |obj, sel, par|
				getApp().mainwindow.onCmdNew( obj, sel, par )
			end
	
			@iconlist.connect( SEL_RIGHTBUTTONRELEASE ) do | obj, sel, par |
				@iconlistmenu.create
				@iconlistmenu.popup( nil, par.root_x, par.root_y )
			end

			@iconlist.connect( SEL_DOUBLECLICKED ) do |obj, sel, par|
				data = @iconlist.getItem( par ).data
				if @mdimenu
					win = TicketEditWindow.new( getApp(), @mdimenu, @mdiclient, data )
				else
					win = TicketEditDialog.new( getApp(), data )
				end
				win.create
				win.show
				if @mdiclient
					@mdiclient.setActiveChild( win )
				end
				1
			end

			populate( list )
		end
	
		#Populates the Listing window.
		def populate( list )
			@iconlist.clearItems
			
			getApp().handler.each([]) do |item|
				
				color = ""
				color =  getApp.options.gui["colors"][ item.data.severity ] if getApp.options.gui and getApp.options.gui["colors"] and item.data.severity
				i = ColorizedIconItem.new( "[#{item.idstring}] #{item.data.name}\t#{item.data.severity}\t#{item.data.status}\t#{item.data.created}\t#{item.data.updated}\t#{item.data.created_by}", nil, nil, color,item  )
				@iconlist << i
			end
		end

	end

	class TicketListDialog < FXDialogBox

		include TicketListWindowBase
	
		def initialize( app, list = [] ) 
			@mdimenu = nil
			@mdiclient = nil
			super( app, "Ticket List", :opts=>DECOR_ALL)
			creategui( app, ID_CLOSE, list )
		end
	
	end
	
	class TicketListWindow < FXMDIChild

		include TicketListWindowBase

		def initialize( app, mdimenu, mdiclient, list = [], icon=nil  ) 
			@mdimenu = mdimenu
			@mdiclient = mdiclient
			super( mdiclient, "Ticket List", icon, mdimenu, 0, mdiclient.numChildren*20, mdiclient.numChildren*20, 640, 480 )
			creategui( app, ID_MDI_CLOSE, list )
		end
	
	end


	#The main window of the application.
	class MyTixWindow < FXMainWindow
	
		def initialize( app )
			super(app, "#{app.options.tickets_directory} - MyTix", :opts => DECOR_ALL, :width => 800, :height => 600)
			menubar = FXMenuBar.new(self, LAYOUT_SIDE_TOP|LAYOUT_FILL_X)
			FXStatusBar.new(self, LAYOUT_SIDE_BOTTOM|LAYOUT_FILL_X|STATUSBAR_WITH_DRAGCORNER)
			@mdiclient = FXMDIClient.new(self, LAYOUT_FILL_X|LAYOUT_FILL_Y)
			@mdimenu = FXMDIMenu.new(self, @mdiclient)
 			FXMDIWindowButton.new(menubar, @mdimenu, @mdiclient, FXMDIClient::ID_MDI_MENUWINDOW, LAYOUT_LEFT)
			FXMDIDeleteButton.new(menubar, @mdiclient, FXMDIClient::ID_MDI_MENUCLOSE, FRAME_RAISED|LAYOUT_RIGHT)
			FXMDIRestoreButton.new(menubar, @mdiclient, FXMDIClient::ID_MDI_MENURESTORE, FRAME_RAISED|LAYOUT_RIGHT)
			FXMDIMinimizeButton.new(menubar, @mdiclient, FXMDIClient::ID_MDI_MENUMINIMIZE, FRAME_RAISED|LAYOUT_RIGHT)
			
			filemenu = FXMenuPane.new(self)
			newCmd = FXMenuCommand.new(filemenu, "&New\tCtl-N\tCreates a new ticket.", getApp().icons.find("16x16/actions/filenew.png") )
			newCmd.connect(SEL_COMMAND, method(:onCmdNew))
			openCmd = FXMenuCommand.new(filemenu, "&Open\tCtl-O\tOpens a list of tickets.", getApp().icons.find("16x16/actions/fileopen.png") )
			openCmd.connect(SEL_COMMAND, method(:onCmdOpen))
			FXMenuCommand.new(filemenu, "&Quit\tCtl-Q\tQuit application.",getApp().icons.find("16x16/actions/exit.png"), getApp(), FXApp::ID_QUIT, 0)
			FXMenuTitle.new(menubar, "&Ticket", nil, filemenu)
		
			windowmenu = FXMenuPane.new(self)
			FXMenuCommand.new(windowmenu, "Tile &Horizontally", nil, @mdiclient, FXMDIClient::ID_MDI_TILEHORIZONTAL)
			FXMenuCommand.new(windowmenu, "Tile &Vertically", nil, @mdiclient, FXMDIClient::ID_MDI_TILEVERTICAL)
			FXMenuCommand.new(windowmenu, "C&ascade", nil, @mdiclient, FXMDIClient::ID_MDI_CASCADE)
			FXMenuCommand.new(windowmenu, "&Close", nil, @mdiclient, FXMDIClient::ID_MDI_CLOSE)
			sep1 = FXMenuSeparator.new(windowmenu)
			sep1.setTarget(@mdiclient)
			sep1.setSelector(FXMDIClient::ID_MDI_ANY)
			FXMenuCommand.new(windowmenu, nil, nil, @mdiclient, FXMDIClient::ID_MDI_1)
			FXMenuCommand.new(windowmenu, nil, nil, @mdiclient, FXMDIClient::ID_MDI_2)
			FXMenuCommand.new(windowmenu, nil, nil, @mdiclient, FXMDIClient::ID_MDI_3)
			FXMenuCommand.new(windowmenu, nil, nil, @mdiclient, FXMDIClient::ID_MDI_4)
			FXMenuCommand.new(windowmenu, "&Others...", nil, @mdiclient, FXMDIClient::ID_MDI_OVER_5)
			FXMenuTitle.new(menubar,"&Window", nil, windowmenu)
   	 
   		 	helpmenu = FXMenuPane.new(self)
		    FXMenuCommand.new(helpmenu, "&About...", getApp().icons.find("16x16/actions/info.png") ).connect(SEL_COMMAND) do
				FXMessageBox.information(self, MBOX_OK, "About MyTix", "File based issue tracking with GUI.\nCreated by Sandor Sipos\n\nUsing:\n - FOX Toolkit: by Jeroen van der Zijp\n - FXRuby: by Lyle Johnson")
   		 	end
			FXMenuTitle.new(menubar, "&Help", nil, helpmenu, LAYOUT_RIGHT)
		end

		#Action to run, when File->New clicked.
		def onCmdNew( obj, sig, par )
			win = TicketEditWindow.new( getApp(), @mdimenu, @mdiclient )
			win.create
			win.show
			@mdiclient.setActiveChild( win )
			return 1
		end

		#Action to run, when File->Open clicked.
		def onCmdOpen( obj, sig, par )
			win =  TicketListWindow.new( getApp(), @mdimenu, @mdiclient )
			win.create
			win.show
			@mdiclient.setActiveChild( win )
			return 1
		end

	end

	#The GUI App class.
	class MyTixApp < FXApp
		#AutoLoader IconDict.
		#Calls original FXIconDict find, if that returns nil, tries to load the image.
		class FXAutoLoadIconDict < FXIconDict

			#Calls original FXIconDict find, if that returns nil, tries to load the image.
			def find( name )
				ret = super
				if ret==nil
					ret = insert( name )
					ret.create if ret
				end
				return ret
			end
		end

	
		#The main window of the application
		attr_accessor :mainwindow

		#The handler for quering Tickets
		attr_reader :handler

		#The icons dict
		attr_reader :icons

		#The application options 
		attr_reader :options
	
		def initialize( options )
			@options = options
			@handler = TicketHandler.new( options )
			@mainwindow = nil
			super( "mytix", "IcoNet")	
			@icons = FXAutoLoadIconDict.new( self, "/usr/share/icons/hicolor:/usr/share/icons/crystalsvg" )
		end

	end
end
end

################################################################################
#
#	Command line parser
#
################################################################################

# Command line parser
class MyTixRunner

	VERSION = '0.0.2'

	#Constructor.
	def initialize
		@application = nil
		yamldir = search_config( Dir.pwd )
		@yamlconfig_defaults = { 
			"cache_directory" => ".ticket_cache", 
			"tickets_directory" => ".tickets", 
			"after_add_ticket" => "",
			"tag" => [],
			"modules" => [],
			"severity" => [ "normal", "blocking", "critical", "minor", "feature", "question" ],
			"status" => [ "opened", "closed", "postponed", "testing" ],
			"console" => { 
				"colors"=>
				{
					"blocking" => "\033[1;31;40m",
					"critical" => "\033[0;31;40m",
					"normal" => "\033[0;35;40m",
					"minor" => "\033[0;33;40m",
					"feature" => "\033[0;34;40m",
					"question" => "\033[0;36;40m"
				}
			},
			"gui" => {
				"enabled" => "true",
				"colors" =>
				{
					"feature" => "#0000FF",
					"normal" => "#CD00CD",
					"critical" => "#FFA000",
					"blocking" => "#FF0000",
					"question" => "#00CDCD",
					"minor" => "#AAAAAA"
				}
			}
		}

		if yamldir!="" 
			yamlconfig = YAML.load_file( File.join( yamldir, '.mytix.yaml' ) )
			yamlconfig["tickets_directory"]=File.join( yamldir, yamlconfig[ "tickets_directory" ] )
			yamlconfig["cache_directory"]=File.join( yamldir, yamlconfig[ "cache_directory" ] )
			#Dir.mkdir( yamlconfig["tickets_directory"] ) 

			yamlconfig.merge( @yamlconfig_defaults )
			yamlconfig_load = yamlconfig
		end
		@options = OpenStruct.new( yamlconfig_load )
		if $fox and @options.gui and @options.gui["enabled"]
			@application = GUI::MyTixApp.new @options
		    FXToolTip.new( @application )
		end
	end

	# Detects the .mytix.yaml file location in the parent directories.
	def search_config( directory )
  		if File.file?( File.join( directory, ".mytix.yaml" ) ) 
			return directory
		else
			parentdir = File.dirname( directory )
			if directory != parentdir
				search_config( parentdir )
			else
				return ""
			end
		end
	end

	#Executes the application.
	#[arguments]
	#	The Array of command line arguments.
	def run( arguments )

		if @application

			case
				when arguments.length == 0
					w = GUI::MyTixWindow.new( @application )
					@application.create
					@application.mainwindow = w
					w.show
					@application.run
					exit 0
				when arguments[0] == "glist"
					w = GUI::TicketListDialog.new( @application )
					@application.create
					w.show
					@application.run
					exit 0
				when arguments[0] == "gadd" 
					t = nil
					t = BOM::Ticket.new( @options, arguments[1]) if arguments.length > 1
					w = GUI::TicketEditDialog.new( @application, t )
					@application.create
					w.show
					@application.run
					exit 0
				when arguments[0] == "gedit"
					th = TicketHandler.new( @options )
					if th.ready_to_run 
						th.filter_by_id( arguments[1] ) do |t|
							w = GUI::TicketEditDialog.new( @application, t )
							@application.create
							w.show
							@application.run
						end
					end
					exit 0
			end
		end

		case
			when arguments[0] == "init"
				File.open( ".mytix.yaml", File::WRONLY|File::TRUNC|File::CREAT) do |f|
					YAML.dump( @yamlconfig_defaults, f )
				end
				exit 0
			when arguments[0] == "add"
				t = BOM::Ticket.new( @options, arguments[ 1 ] ) 
				t.save
				exit 0
			when arguments[0] == "list"
				th = TicketHandler.new( @options )
				if th.ready_to_run 
					if th.length > 0
						print "Listing Tickets from #{@options.tickets_directory}\n"
						t = Console::Tabular.new( [ "Id", "Name", "status", "created" ] )
						th.each( arguments[1, arguments.length ] ) do |i|
							c = nil
							c = @options.console["colors"][ i.data.severity ] if @options.console and @options.console["colors"]
							t << { "color"=>c, "cols"=>[ i.idstring, i.data.name, i.data.status, i.data.created ] }
						end
						t.print
					else
						puts "No tickets in the database"
					end
				end

				exit 0
			when arguments[0] == "comment"
				th = TicketHandler.new( @options )
				th.filter_by_id( arguments[1]) do |t|
					t.addComment( arguments[2] ) 
					t.save() 
				end
				exit 0
			when arguments[0] == "attach"
				th = TicketHandler.new( @options )				
				th.filter_by_id( arguments[1]) do |t|
					t.addAttachments( arguments[2..arguments.length] ) 
					t.save()
				end
				exit 0
			when arguments[0] == "status"
				th = TicketHandler.new( @options )
				th.filter_by_id( arguments[1] ) do |t|
					if t.setStatus( arguments[2] ) 
						t.save() 
					end
				end
				exit 0
			when arguments[0] == "show"
				th = TicketHandler.new( @options )
				th.filter_by_id( arguments[1] ) do |t|
					ct = Console::Tabular.new( nil, ["r", "l"], 2 )
					c = @options.console["colors"][ t.data.severity ] if @options.console and @options.console["colors"]
					ct << {"cols"=>["Id:", t.idstring]}
					ct << {"cols"=>["Name:", t.data.name ]}
					ct << {"cols"=>["Description:", t.data.description ]}
					ct << {"cols"=>["Status:", t.data.status ]}
					ct << {"cols"=>["Severity:", t.data.severity ]}
					ct << {"cols"=>["Created by:", t.data.created_by ]}
					ct << {"cols"=>["Created:", t.data.created ]}
					ct << {"cols"=>["Updated:", t.data.updated ]}
					ct.print

					t.loadComments
					if t.comments.length>0
						puts ""
						puts "Comments:"
						ct = Console::Tabular.new( ["Comment", "Created", "Created by"]  )
						t.comments.each do | c |
							ct << {"cols"=>[c.comment, c.created, c.created_by ]}
						end
						ct.print
					end

					t.loadAttachments
					if t.attachments.length > 0
						puts ""
						puts "Attachments:"
						ct = Console::Tabular.new( [ "Id", "Attachment", "Attachment comment", "Created", "Created by", "Full path"]  )
						t.attachments.each do | a |
							p1 = Pathname.new( File.join( File.dirname(t.filename), "attachments", a.fileid, a.original_name ) )
							p2 = Pathname.new( Dir.pwd )
							ct << {"cols"=>[a.fileid, a.original_name, a.comment, a.created, a.created_by,  p1.relative_path_from( p2 ) ]}
						end
						ct.print
					end
				end
				exit 0

			when (arguments[0] == "-v" or arguments[0] == "--version" )
      			puts "#{File.basename(__FILE__)} version #{VERSION}"
				exit 0
			when ( arguments[0] == "-h" or arguments[0] == "--help" )
      			puts "#{File.basename(__FILE__)} version #{VERSION}"
      			RDoc::usage("usage") #exits app
				exit 0
		end	
    end
end

if __FILE__ == $0
	app = MyTixRunner.new
	app.run(ARGV)
end
