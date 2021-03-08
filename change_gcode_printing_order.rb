infile = "test.gcode"
outfile = "foo.gcode"

gcode=File.read(infile)

e=0

sections = []
# start_height, min_x, min_y, max_x, max_y
sections_for_layer = Hash.new { |h,k| h[k] = [] }


$min_distance = 50 # 5cm freedom around the nozzle

#layer_xy_shift=1 # just testing # a line on the next layer may be 1mm outside the section

oldpos={"X"=>0, "Y"=>0, "Z"=>0}
olde=nil

def calc_distance(a,b)
	_calc_distance(a["X"], a["Y"], b["X"], b["Y"])
end

def _calc_distance(x1, y1, x2, y2)
	Math.sqrt((x1 - x2)**2 + (y1 - y2)**2)
end

def check_if_2d_layer_contains(s1, s2)
	return false if s1[:obsolete]==true || s2[:obsolete]==true
	(s1[:min_x]-$min_distance < s2[:min_x] && s2[:max_x] < s1[:max_x]+$min_distance) &&
	(s1[:min_y]-$min_distance < s2[:min_y] && s2[:max_y] < s1[:max_y]+$min_distance)
end

# will change s1
def merge_sections(s1, s2)
	%i(min_x max_x min_y max_y max_z_below).each{|k|
		next unless s1.has_key?(k)
		s1[k] = [s1[k], s2[k]||999].send(k.to_s.split("_").first)
	}
	s1[:extruded] += s2[:extruded]
end

def match_g0g1(line)
	data=line.strip.match(/G(?<ACTION>[01]) (F(?<F>[.0-9]*)\s?)?(X(?<X>[.0-9]*)\s?)?(Y(?<Y>[.0-9]*)\s?)?(Z(?<Z>[.0-9]*)\s?)?(E(?<E>([.0-9-]*)\s?))?/) #FIXME: don't assume this order is correct..
end


def extend_section(section, pos)
	section[:min_x]=[section[:min_x], pos["X"]].min
	section[:max_x]=[section[:max_x], pos["X"]].max
	section[:min_y]=[section[:min_y], pos["Y"]].min
	section[:max_y]=[section[:max_y], pos["Y"]].max
end

section=nil
epositioning=nil

gcode.split("\n").each{|line|
	if line=~/^G91/
		epositioning=:relative
	elsif line=~/^G92 E0/
		epositioning=:absolute
		olde=0
		next
	end

	data = match_g0g1(line)
	next unless data

	newpos=oldpos.dup
	newe=olde

	data.named_captures.each{|k,v|
		newpos[k] = v.to_f if v&& %w(X Y Z).include?(k)
		newe=v.to_f if v&&k=='E'
	}

	extruded = newe ? (epositioning==:absolute ? newe-olde : newe) : 0

	action = data['E'] ? :print : :move

	if oldpos["Z"] != newpos["Z"] # layer change..
		section=nil
#		puts "bumped to layer #{newpos["Z"]}"
	end

	distance = calc_distance(oldpos, newpos)

	if(!section || action == :move && distance > $min_distance) # move without printing
		#pp [:distance, distance]
		#if(distance > $min_distance)
		# check if we already have a section for that
		section = sections_for_layer[newpos["Z"]].find{|s|
			s[:min_x]-$min_distance < newpos["X"] && newpos["X"] < s[:max_x]+$min_distance &&
			s[:min_y]-$min_distance < newpos["Y"] && newpos["Y"] < s[:max_y]+$min_distance 
		}

	end

	if section
		extend_section(section, newpos)
	else
		if extruded > 0
#			puts "new section: height #{newpos["Z"]}"
			if action==:print
				posx = [oldpos["X"], newpos["X"]]
				posy = [oldpos["Y"], newpos["Y"]]
			else
				posx = [newpos["X"]]
				posy = [newpos["Y"]]
			end
			section = {min_x: posx.min, max_x: posx.max, min_y: posy.min, max_y: posy.max, extruded: 0, sections_above: []}
			sections_for_layer[newpos["Z"]] << section
		end
	end


	section[:extruded] += extruded if section

	oldpos = newpos
	olde = newe
}

sections_for_layer.each{|_,b| b.reject!{|b| b[:extruded]==0}}.select!{|_,c| c!=[]}


sections_for_layer.each{|_,sections|
	sections.permutation(2).each{|s1,s2|
		if check_if_2d_layer_contains(s1, s2)
			merge_sections(s1, s2)
			s2[:obsolete]=true
		end
	}
}


layer_heights=sections_for_layer.keys.sort.reverse + [0]


layer_heights.each_cons(2) {|height, lower_height|
	sections = sections_for_layer[height]
	sections.map{|section|
		# check if the previous layer contains a section, on which more than one section of the current layer is built
		sections_for_layer[lower_height].each{|section_below| section_below[:max_z_below]||=height}

		sections_for_layer[lower_height].select{|section_below|
			check_if_2d_layer_contains(section_below, section)
		}.each{|l|
			l[:sections_above] << section
		}
	}
	# take the ones with count=1 and extend them with the ones above
	sections_for_layer[lower_height].each{|section_below|
		if section_below[:sections_above].count == 1
			merge_sections(section_below, section_below[:sections_above].first)
			section_below[:sections_above].first[:obsolete]=true
		end

	}
}

sections_for_layer.each{|_,b| b.reject!{|b| b[:obsolete]==true}}.select!{|_,c| c!=[]}
count=0

sections_for_layer.each{|a,b| b.each{|l|
		l.delete(:sections_above)
		l[:min_z]=a
		l[:count]=count+=1
	}
}

sections.reject!{|s| s[:min_z] == 0.28 } # adjust accordingly!

sections = sections_for_layer.values.flatten

puts "identified sections:"
pp sections

# now all moves are in a section! - change order of my moves accordingly, as all has the relevant clearings, I can just go over all G1 moves, see if they are in the sections and if yes, execute them (while maintaining the extrude distance)

old_pos={"X"=>0, "Y"=>0, "Z"=>0}
old_e=0

new_file = []
new_sections = nil

gcode.split("\n").each_with_index{|line, i|
	line.strip!
	#G91 - all code after this will just be added to the end of the file
	if line=~/^M140 S0$/ || new_sections == [ 999 ]
		new_sections = [ 999 ]
	elsif line=~/^G92 E0/
		epositioning=:absolute
		old_e=0
		next
	end
	# TODO: handle relative extrusion (G91/M83). For now we just assume absoulte always...

	data = match_g0g1(line)

	if new_sections == [ 999 ]
		new_line = line
	elsif data # we've got a position!

		# parse xyz and extruder movement. Also the Feedrate is useful to know
		new_pos=old_pos.dup
		new_e=old_e # in case we don't have updated values
		data.named_captures.each{|k,v|
			new_pos[k] = v.to_f if v&& %w(F X Y Z).include?(k) # note: here we also have F in... although it's not a position
			new_e=v.to_f if v&&k=='E'
		}

		#pp [:new_e, new_e]
		#pp [:old_e, old_e]
		extruded = new_e ? (epositioning==:absolute ? new_e-old_e : new_e) : 0

		new_data = new_pos.dup
		new_data[:e_diff] = 0
		if data['ACTION'] == '1'
			new_data[:e_diff] = extruded
		end

#		puts "--"
#		puts i+1
#		puts line
#		pp new_data


		# find belonging section. we do this only when stuff is extruded (G1, data.named_captures.has_key?("E"))
		if true #data['ACTION'] == '1' && data.named_captures.has_key?("E")
			new_sections = sections.select{|s|
				s[:min_z] <= new_pos["Z"] && new_pos["Z"] < s[:max_z_below] &&
				s[:min_x] <= new_pos["X"] && new_pos["X"] <= s[:max_x]  &&
				s[:min_y] <= new_pos["Y"] && new_pos["Y"] <= s[:max_y]
			}.map{|s| s[:count]}
			if new_sections.count>1
				pp [new_pos, new_sections]
				raise 'too_many_sections'
			end
		end

		
		new_line = ["G#{data['ACTION']} ", new_data, "; orig line #{i+1}"]

	else
		if old_pos["X"] == 0 # if not started to really print
			new_sections = [ 0 ]
		else # put this code into all sections. may be e.g. fan speed changes
			new_sections = sections.select{|s|
				s[:min_z] <= old_pos["Z"] && old_pos["Z"] < s[:max_z_below]
			}.map{|s| s[:count]}
		end
		new_line = line

	end

	new_file << [new_sections, new_line]
	
	old_pos = new_pos if new_pos
	old_pos.delete("F") # we don't need this anymore
	old_e = new_e if new_e
}

#pp new_file

File.open(outfile, "w"){|f|
	extruder_pos = 0

	new_file.transpose.first.flatten.uniq.sort.each{|i|
		new_file.each{|j, line|
			if j.include?(i)
				if line.is_a?(Array)
					data = line[1]
					e_diff = data.delete(:e_diff) || 0
					data.merge!({'E' => extruder_pos += e_diff}) if e_diff!=0
					line = line[0] + data.to_a.map{|a,b| a+b.round(5).to_s}.join(" ") + line[2].to_s
				end
				f.write(line + " ; for section #{i}\n" )
			end
		}
		if i>0
			section = sections[i]
			f.write("G0 X#{((section[:min_x] + section[:max_x]) /2).round(3)} Y#{((section[:min_y] + section[:max_y]) /2).round(3)} F8998") if section
		end

	}
}

