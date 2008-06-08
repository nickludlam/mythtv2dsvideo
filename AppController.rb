#
# AppController.rb
# MythTV2DSVideo
#
# Copyright (c) 2008 Nick Ludlam
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require 'osx/cocoa'
require 'open3'
require 'rubygems'
require 'ruby-mythtv'

class AppController < OSX::NSObject
  include OSX

  # Not entirely sure where the 'proper' place for these is. Possibly
  # ~/Library/Caches, but I'm not sure if anything sweeps those?
  THUMBNAIL_LOCATION = "/tmp/myth2dsvideo_thumb_%s.png"
  
  # TODO: Make the dsvideo encoder part of the Application bundle
  DSVIDEO_ENCODE_CMD = "%s/dsvideo -n 30000 -s -o ~/Desktop/%s.dsv > /dev/null"
  
  ib_outlets :prefsWindow, :mainWindow, :recordingsTable, :recordingDescription, \
             :encodeButton, :encodeProgressText, :encodeBar, :backendHost

  # @recordings is an empty array until we have queried a backend server
  def initialize
    @recordings = []
  end

  def awakeFromNib
    # Set up our table geometry and columns. This doesn't seem to come
    # across from the NIB file?
    @recordingsTable.rowHeight = 64
    
    @recordingsTable.tableColumns[0].setIdentifier("Preview")
    @recordingsTable.tableColumns[1].setIdentifier("Date")
    @recordingsTable.tableColumns[2].setIdentifier("Channel")
    @recordingsTable.tableColumns[3].setIdentifier("Title")
    
    # Blank the recordingDescription field
    @recordingDescription.delete(nil)
    
    # Set up the Preview column in the recordingsTable to contain NSImageCell objects
    cell = OSX::NSImageCell.new
    cell.imageAlignment = OSX::NSImageAlignLeft
    @recordingsTable.tableColumnWithIdentifier("Preview").DataCell = cell
  end

  def applicationDidFinishLaunching(sender)
    displayPrefs(self)
  end

  # Gotcha: Make sure you set the delegate of the NIB file's owner to this controller
  def applicationShouldTerminateAfterLastWindowClosed(application)
    true
  end
  
  def windowShouldClose(notification)
    return true unless @encode_thread && @encode_thread.alive?
    
    @alert = OSX::NSAlert.alloc.init
    @alert.messageText = "Do you really want to close the application and terminate the current encoding?"
    @alert.alertStyle = OSX::NSCriticalAlertStyle
    @alert.addButtonWithTitle("Quit")
    @alert.addButtonWithTitle("Cancel")
    @alert.beginSheetModalForWindow_modalDelegate_didEndSelector_contextInfo(
      @mainWindow, self, "alertDidEnd:returnCode:contextInfo:", nil)
    false
  end
  
  def alertDidEnd_returnCode_contextInfo(alert, code, contextInfo)
    if (code == OSX::NSAlertFirstButtonReturn)
      @stream_should_exit = true
      NSLog("Running thread.join(2)")
      # Allow a two second timeout for the encode thread to terminate
      @encode_thread.join(2)
      NSLog("After thread.join(2)")

      # Close the backend connection and then exit the app
      @backend.close
      @mainWindow.close
    else
      false
    end
  end
  
  ib_action :refresh
  def refresh
    begin
      # Close the previous connection if one exists
      @backend.close if @backend
      @backend = MythTV::Backend.new(:host => @backendHost.stringValue)
    rescue
      # TODO: Alert the user that instantiation has failed for whatever reason
      return
    end
    
    @recordings = @backend.query_recordings
    #OSX.NSLog("Got back %@ recordings", @recordings.length)

    # Thread the preview image generation so we can update the encodeProgressText
    Thread.start do
      begin
        preview_image_connection = MythTV::Backend.new(:host => @backendHost.stringValue)
      
        @recordings.each_with_index do |rec, i|
          next if File.exists?(THUMBNAIL_LOCATION % rec.filename)
          @encodeProgressText.setStringValue("Generating preview #{i+1}/#{@recordings.length}")
          File.open(THUMBNAIL_LOCATION % rec.filename, 'w') { |file| file.write(preview_image_connection.preview_image(rec, :height => 64)) }
          #OSX.NSLog("Created thumbnail #{THUMBNAIL_LOCATION % rec.filename}")
        end
      ensure
        # If there are any exceptions, ensure we've closed the preview_image_connection
        preview_image_connection.close
        @encodeProgressText.setStringValue("Status: Idle")
        @recordingsTable.reloadData
      end
    end
  end
  
  ib_action :displayPrefs
  def displayPrefs(sender)
    # Open the sheet to collect the backend hostname
    NSApp.beginSheet_modalForWindow_modalDelegate_didEndSelector_contextInfo(@prefsWindow, @mainWindow, self, :prefsDidEndSheet_returnCode_contextInfo, nil)
  end
  
  ib_action :closePrefs
  def closePrefs(sender)
    NSApp.endSheet_returnCode(@prefsWindow, 0)
  end
  
  def prefsDidEndSheet_returnCode_contextInfo(sheet, returnCode, context)
    NSLog("Host to connect to is #{@backendHost.stringValue}")
    sheet.orderOut(nil)
    refresh
    NSLog("Finished prefsDidEnd")
  end

  # Returns the numbers of rows in the array for NSTableView to display.
  # Gotcha: Make sure you set your controller class as the tableView delegate!
  def numberOfRowsInTableView(aTableView)
    return @recordings.length
  end

  # Uses the @columns array to to enable a flexible number of columns when fetching data.
  def tableView_objectValueForTableColumn_row(aTable, aTableColumn, rowIndex)
    recording = @recordings[rowIndex]
    case aTableColumn.identifier
    when "Date"
      recording.start.strftime("%a, %b %d\n%I:%M %p")
    when "Channel":
      recording.channame
    when "Title":
      recording.title + "\n" + recording.subtitle + "\n" + humanizeFilesize(recording.filesize) + "/" + humanizeDuration(recording.duration)
    when "Preview":
      OSX::NSImage.alloc.initWithContentsOfFile(THUMBNAIL_LOCATION % recording.filename)
    else
      "Unknown"
    end
  end
  
  def tableViewSelectionDidChange(notification)
    @recordingDescription.setString(@recordings[@recordingsTable.selectedRow].description)
  end
  
  ib_action :threadStart
  def threadStart(sender)
    NSLog("@encode_thread is #{@encode_thread.inspect}")
    NSLog("@encode_thread.status is #{@encode_thread.status}") if @encode_thread
    
    # If the user has pushed 'Stop' on an encode, signal that the stream
    # should stop, and the encode and thread should conclude
    if @encode_thread && @encode_thread.alive?
      @stream_should_exit = true
      return
    end
    
    @encode_thread = Thread.start do
      selected_recording = @recordings[@recordingsTable.selectedRow]
            
      # Derive our filename
      dsv_filename =  selected_recording.title
      dsv_filename += "_" + selected_recording.subtitle unless selected_recording.subtitle == ""
      dsv_filename.gsub!(/[^A-Za-z0-9]+/, "_")
      
      @encodeButton.setTitle("Stop")
      @encodeBar.startAnimation(self)
      @encodeProgressText.setStringValue("Initialising...")

      NSLog(DSVIDEO_ENCODE_CMD % [File.dirname(__FILE__), dsv_filename])
      Open3.popen3(DSVIDEO_ENCODE_CMD % [File.dirname(__FILE__), dsv_filename]) do |stdin, stdout, stderr|
        total_bytes_in = 0
        
        # Start streaming the requested recording into the DSVideo encoder
        @backend.stream(selected_recording) do |data|
          stdin.write(data)
          total_bytes_in += data.length
          percentage_complete = (total_bytes_in / selected_recording.filesize.to_f) * 100
          @encodeBar.setDoubleValue(percentage_complete)
          @encodeProgressText.setStringValue("%.2f%% complete" % percentage_complete)
          break if @stream_should_exit
        end
      end
      
      @encodeProgressText.setStringValue("Encode finished!")
      @encodeBar.stopAnimation(self)
      @encodeBar.setDoubleValue(0.0)      
      @stream_should_exit = false
      @encodeButton.setTitle("Start")
    end
  end

  def humanizeFilesize(size)
    size = size.to_f
    return ("%.2f B" % size) if size < 1023
    size = size / 1024
    return ("%.2f kB" % size) if size < 1023
    size = size / 1024
    return ("%.2f MB" % size) if size < 1023
    size = size / 1024
    return ("%.2f GB" % size)
  end
  
  def humanizeDuration(duration)
    return "%d minutes" % (duration / 60)
  end
  
end