////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2017, Matt Dew
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
/*! \class axi_seq
 *  \brief Writes to memory over AXI, backdoor readback, then AXI readback
 *
 *  miscompares are flagged.
 */
class axi_seq extends uvm_sequence #(axi_seq_item);

  `uvm_object_utils(axi_seq)

  const int axi_readback  = 1;
  const int clearmemory   = 0;
  const int postcheck     = 1;
  const int precheck      = 1;
  const int window_size   = 'h1000;
  const int xfers_to_send = 30;

  const int pipelined_bursts_enabled=0;



  int addr_width=0;
  int data_width=0;
  int id_width=0;
  int len_width=0;
  int xfers_done=0;

  memory m_memory;

  axi_seq_item write_item [];
  axi_seq_item read_item  [];


  extern function   new (string name="axi_seq");
  extern task       body;
  extern function void response_handler(uvm_sequence_item response);

  extern function void set_addr_width(int width=0);
  extern function void set_data_width(int width=0);
  extern function void set_id_width(int width=0);
  extern function void set_len_width(int width=0);

  extern function bit compare_items (int xfer_cnt);
  extern function bit check_memory(ref axi_seq_item item,
                               input bit [63:0] lower_addr,
                               input bit [63:0] upper_addr);

endclass : axi_seq


// This response_handler function is enabled to keep the sequence response FIFO empty
function void axi_seq::response_handler(uvm_sequence_item response);

axi_seq_item item;
int xfer_cnt;

$cast(item,response);

$cast(read_item[item.id], item.clone);
xfer_cnt=item.id;
   xfers_done++;
  `uvm_info(this.get_type_name(), $sformatf("SEQ_response_handler xfers_done=%0d.   Item: %s",xfers_done, item.convert2string()), UVM_INFO)

 if (item.cmd== e_READ_DATA) begin

    `uvm_info("axi_seq::response_handler::READBACK COMPARE", $sformatf("Now comparing axi write transfer %0d with axi read transfer %0d", xfer_cnt, xfer_cnt), UVM_INFO)
    assert (compare_items (.xfer_cnt(xfer_cnt)));
   end

endfunction: response_handler

/*! \brief Constructor
 *
 * Doesn't actually do anything except call parent constructor
 */
function axi_seq::new (string name="axi_seq");
  super.new(name);
endfunction : new

/*! \brief Set Address bus width
 *
 * AXI supports multiple bus widths, parameterized at runtime.
 * We have to tell the sequence so we can randomize accordingly.
 * IE: If the addr bus width is 32, don't try to use 64 bits.
 */
function void axi_seq::set_addr_width (int width=0);
  this.addr_width = width;
endfunction : set_addr_width

/*! \brief Set Data bus width
 *
 * AXI supports multiple bus widths, parameterized at runtime.
 * We have to tell the sequence so we can randomize accordingly.
 * IE: If the data bus width is 32, don't send a burst_size=64bits.
 */
function void axi_seq::set_data_width (int width=0);
  this.data_width = width;
endfunction : set_data_width

/*! \brief Set ID vector width
 *
 * AXI supports  ID widths, parameterized at runtime.
 * We have to tell the sequence so we can randomize accordingly.
 */
function void axi_seq::set_id_width (int width=0);
  this.id_width = width;
endfunction : set_id_width

/*! \brief Set length vector width
 *
 * AXI supports 2 different AxLEN widths, parameterized at runtime.
 * 4-bit and 8-bit.
 * We have to tell the sequence so we can randomize accordingly.
 *
 */
function void axi_seq::set_len_width (int width=0);
  this.len_width = width;
endfunction : set_len_width

/*! \brief Does all the work.
 *
 * -# Creates constrained random AXI write packet
 * -# Sends it
 * -# Backdoor read of memory to verify correctly written
 * -# Creates constrained random AXI read packet with same len and address as write packet
 * -# Sends it
 * -# Verifies read back data with written data.
 *
 *  two modes:
 *     Serial, Write_addr,  then write, then resp.  Repeat
 *     Parallel - Multiple write_adr, then multiple write_data, then multiple  resp, repeat
 */
task axi_seq::body;

  string s;
  bit [7:0] read_data;
  bit [7:0] expected_data;



  bit [63:0] Lower_Wrap_Boundary;
  bit [63:0] Upper_Wrap_Boundary;
  bit [63:0] iaddr;
  bit [63:0] addr_lo;
  bit [63:0] addr_hi;

  int idatacntr;
  int miscompare_cntr;
  string write_item_s;
  string read_item_s;
  string expected_data_s;
  string msg_s;
  string localbuffer_s;
  int rollover_cnt;
  bit [7:0] xid;

  bit [7:0] expected_data_array [];

  bit [2:0] max_burst_size;
  int yy;
  bit [7:0] localbuffer [];

  xfers_done=0;

  write_item = new [xfers_to_send];
  read_item  = new [xfers_to_send];


  use_response_handler(pipelined_bursts_enabled); // Enable Response Handler

  if (!uvm_config_db #(memory)::get(null, "", "m_memory", m_memory)) begin
    `uvm_fatal(this.get_type_name, "Unable to fetch m_memory from config db. Using defaults")
    end


  // If addr_width==0, then the setter hasn't been called. Try to fetch from
  // config db.
  if (addr_width == 0) begin
    if (!uvm_config_db #(int)::get(null, "", "AXI_ADDR_WIDTH", addr_width)) begin
        `uvm_fatal(this.get_type_name,
                   "Unable to fetch AXI_ADDR_WIDTH from config db. Using defaults")
     end
  end

  // If data_width==0, then the setter hasn't been called. Try to fetch from
  // config db.
  if (data_width == 0) begin
     if (!uvm_config_db #(int)::get(null, "", "AXI_DATA_WIDTH", data_width)) begin
        `uvm_fatal(this.get_type_name,
                   "Unable to fetch AXI_DATA_WIDTH from config db. Using defaults")
     end
  end

  // If id_width==0, then the setter hasn't been called. Try to fetch from
  // config db.
  if (id_width == 0) begin
    if (!uvm_config_db #(int)::get(null, "", "AXI_ID_WIDTH", id_width)) begin
        `uvm_fatal(this.get_type_name,
                   "Unable to fetch AXI_ID_WIDTH from config db. Using defaults")
     end
  end

  // If id_width==0, then the setter hasn't been called. Try to fetch from
  // config db.
  if (len_width == 0) begin
    if (!uvm_config_db #(int)::get(null, "", "AXI_LEN_WIDTH", len_width)) begin
        `uvm_fatal(this.get_type_name,
                   "Unable to fetch AXI_LEN_WIDTH from config db. Using defaults")
     end
  end

      max_burst_size=$clog2(data_width/8);

    `uvm_info(this.get_type_name(),
              $sformatf("DATA_BUS_WIDTH:  %0d  max_burst_size: %0d",
                        data_width, max_burst_size),
              UVM_HIGH)

  // Clear memory
  // AXI write
  // direct readback of memory
  //  check that addresses before Axi start address are still 0
  //  chck expected data
  //  check that addresses after axi start_addres+length are still 0

  for (int xfer_cnt=0;xfer_cnt<xfers_to_send;xfer_cnt++) begin

    // clear memory
    if (clearmemory==1) begin
       for (int i=0;i<window_size;i++) begin
          m_memory.write(i, 'h0);
       end
    end

    write_item[xfer_cnt] = axi_seq_item::type_id::create("write_item");
    read_item[xfer_cnt]  = axi_seq_item::type_id::create("read_item");


    // Not sure why I have to define and set these and
    // then use them in the randomize with {} but
    // Riviera Pro works better like this.
    addr_lo=xfer_cnt*window_size;
    addr_hi=addr_lo+'h100;
    xid =xfer_cnt & 8'hFF;
    start_item(write_item[xfer_cnt]);

    `uvm_info(this.get_type_name(),
              $sformatf("item %0d id:0x%0x addr_lo: 0x%0x  addr_hi: 0x%0x",
                        xfer_cnt, xid, addr_lo,addr_hi),
              UVM_INFO)


    assert( write_item[xfer_cnt].randomize() with {
                                         cmd        == e_WRITE;
                                         burst_size <= local::max_burst_size;
                                         id         == local::xid;
                                         addr       >= local::addr_lo;
                                         addr       <  local::addr_hi;
                                         //len        <= 'h40;
      //(addr + len) <= local::window_size;
                                         //protocol   ==     e_AXI3;
                                        //burst_size inside {e_1BYTE};
                                         //burst_type inside {e_FIXED, e_INCR, e_WRAP};
                                         //id == local::i;

//       Protocol: e_AXI3 Cmd: e_WRITE    Addr = 0xe  ID = 0x1  Len = 0x14 (20)  BurstSize = 0x1  BurstType = 0x1
 //     protocol == e_AXI3;
//     addr == 'he;
      len < 'h14;
     // burst_size == 'h1;
     // burst_type == 'h1;

    })
    `uvm_info("DATA", $sformatf("\n\n\nItem %0d:  %s", xfer_cnt, write_item[xfer_cnt].convert2string()), UVM_INFO)
    finish_item(write_item[xfer_cnt]);

    if (pipelined_bursts_enabled != 1) begin
       get_response(write_item[xfer_cnt]);

      if (!check_memory(.item       (write_item[xfer_cnt]),
                        .lower_addr (xfer_cnt*window_size),
                        .upper_addr ((xfer_cnt+1)*window_size))) begin
        `uvm_info("MISCOMPARE","Miscompare error", UVM_INFO)
      end

    end
  end  //for

  #2us
  // \todo: setup so read memm and axireadback don't commense until write
  // response is received.
  //

  //use_response_handler(0); // Enable Response Handler
if (axi_readback==1) begin

    // Now AXI readback
    `uvm_info("READBACK", "Now READING BACK via AXI", UVM_INFO)

  for (int xfer_cnt=0;xfer_cnt<xfers_to_send;xfer_cnt++) begin

    `uvm_info("...", "Now reading back from memory to verify - DONE", UVM_LOW)

    start_item(read_item[xfer_cnt]);
    assert( read_item[xfer_cnt].randomize() with {protocol   == write_item[xfer_cnt].protocol;
                                                  cmd        == e_READ;
                                                  burst_size == write_item[xfer_cnt].burst_size;
                                                  id         == write_item[xfer_cnt].id;
                                                  burst_type == write_item[xfer_cnt].burst_type;
                                                  addr       == write_item[xfer_cnt].addr;
                                                  len        == write_item[xfer_cnt].len;}
                                                                          ) else begin
         `uvm_error(this.get_type_name(),
                    $sformatf("Unable to randomize %s",  read_item[xfer_cnt].get_full_name()));
         end  //assert


    finish_item(read_item[xfer_cnt]);

    if (pipelined_bursts_enabled != 1) begin
       get_response(read_item[xfer_cnt]);   //response_handler above deals with this
    end

    `uvm_info(this.get_type_name(),
              $sformatf("GOT RESPONSE. item=%s", read_item[xfer_cnt].convert2string()),
              UVM_INFO)
  end

 //   `uvm_info("...", "Now comparing AXI readback to AXI write data", UVM_INFO)
  //for (int xfer_cnt=0;xfer_cnt<xfers_to_send;xfer_cnt++) begin
    //`uvm_info("READBACK COMPARE", $sformatf("Now comparing axi write  transfer %0d with axi read transfer %0d", xfer_cnt, xfer_cnt), UVM_INFO)
     //compare_items (.xfer_cnt(xfer_cnt));
  //end  //for

end // if axi_readback=1

    `uvm_info("..", "...", UVM_HIGH)


  #10us

  `uvm_info(this.get_type_name(), "SEQ ALL DONE", UVM_INFO)

endtask : body


function automatic bit axi_seq::check_memory(
                ref axi_seq_item item,
                input bit [63:0] lower_addr,
                input bit [63:0] upper_addr);


  int max_beat_cnt;
  int dtsize;

  bit [63:0] Lower_Wrap_Boundary;
  bit [63:0] Upper_Wrap_Boundary;
  bit [63:0] iaddr;

  bit [63:0]  pre_check_start_addr;
  bit [63:0]  pre_check_stop_addr;

  bit [63:0]  check_start_addr;
  bit [63:0]  check_stop_addr;

  bit [63:0]  post_check_start_addr;
  bit [63:0]  post_check_stop_addr;


 //  string write_item_s;
  int idatacntr;
  int miscompare_cntr;
  string write_item_s;
  string read_item_s;
  string expected_data_s;
  string actual_data_s;
  string msg_s;
  string localbuffer_s;
  int rollover_cnt;

  bit [7:0] expected_data_array [];
  bit [7:0] actual_data_array [];

  bit [2:0] max_burst_size;
  int yy;
  bit [7:0] localbuffer [];
  bit [7:0] read_data;
  bit [7:0] expected_data;


  assert (item != null);

  if (item == null) begin
    `uvm_fatal(this.get_type_name(), "Item is null")
  end




    //***** Readback
    `uvm_info("...", "Now reading back from memory to verify", UVM_LOW)


    if (item.burst_type == e_WRAP) begin


      max_beat_cnt = axi_pkg::calculate_axlen(.addr(item.addr),
                                              .burst_size(item.burst_size),
                                              .burst_length(item.len)) + 1;

      dtsize = (2**item.burst_size) * max_beat_cnt;

      Lower_Wrap_Boundary = (int'(item.addr/dtsize) * dtsize);
      Upper_Wrap_Boundary = Lower_Wrap_Boundary + dtsize;

      pre_check_start_addr  = lower_addr;
      pre_check_stop_addr   = Lower_Wrap_Boundary;

      check_start_addr      = Lower_Wrap_Boundary;
      check_stop_addr       = Upper_Wrap_Boundary;

      post_check_start_addr = Upper_Wrap_Boundary;
      post_check_stop_addr  = upper_addr;

    end else begin
       pre_check_start_addr=lower_addr;
       pre_check_stop_addr= item.addr; // only different if burst_type=e_WRAP;

       check_start_addr=item.addr;
       check_stop_addr=item.addr+item.len;

       post_check_start_addr=item.addr+item.len;
       post_check_stop_addr=upper_addr;
    end

    msg_s="";
  $sformat(msg_s, "%s Item: %s",                     msg_s, item.convert2string());
  $sformat(msg_s, "%s pre_check_start_addr: 0x%0x",  msg_s, pre_check_start_addr);
  $sformat(msg_s, "%s pre_check_stop_addr: 0x%0x",   msg_s, pre_check_stop_addr);
  $sformat(msg_s, "%s check_start_addr: 0x%0x",      msg_s, check_start_addr);
  $sformat(msg_s, "%s check_stop_addr: 0x%0x",       msg_s, check_stop_addr);
  $sformat(msg_s, "%s post_check_start_addr: 0x%0x", msg_s, post_check_start_addr);
  $sformat(msg_s, "%s post_check_stop_addr: 0x%0x",  msg_s, post_check_stop_addr);
  $sformat(msg_s, "%s Lower_Wrap_Boundary: 0x%0x",   msg_s, Lower_Wrap_Boundary);
  $sformat(msg_s, "%s Upper_Wrap_Boundary: 0x%0x",   msg_s, Upper_Wrap_Boundary);


    `uvm_info("CHECK MEMORY",
            msg_s,
            UVM_INFO)



     miscompare_cntr=0;

    // compare pre-data
    if (precheck==1) begin
        expected_data='h0;
        for (int i=pre_check_start_addr;i<pre_check_stop_addr;i++) begin
             read_data=m_memory.read(i);
             assert(expected_data==read_data) else begin
                miscompare_cntr++;
                `uvm_error("e_FIXED miscompare",
                           $sformatf("expected: 0x%0x   actual:0x%0x",
                                     expected_data,
                                     read_data))
             end
          end
     end // if precheck

     // compare data
     if (item.burst_type == e_FIXED) begin

       expected_data_array = new[2**item.burst_size];
       actual_data_array   = new[2**item.burst_size];
       localbuffer         = new[2**item.burst_size];
      // brute force, not elegant at all.
      // write to local buffer, then compare that buffer (repeated) with the axi readback


      yy=0;

      for (int y=0;y<localbuffer.size();y++) begin
         localbuffer[y]='h0;
      end
      for (int y=0;y<item.len;y++) begin
        localbuffer[yy++]=item.data[y];
        if (yy >= 2**item.burst_size) begin
          yy=0;
        end
      end

      yy=0;
      for (int y=0; y<expected_data_array.size(); y++) begin
        expected_data_array[y]=localbuffer[yy++];
        if (yy >= localbuffer.size()) begin
          yy=0;
        end
      end
/*
      for (int y=0;y<item.data.size();y++) begin
         expected_data = expected_data_array[y];
         read_data     = m_memory.read(item.addr+y);
        actual_data_array[y] = read_data;
         if (expected_data!=read_data) begin
            miscompare_cntr++;
         end
      end
*/

       // on a fixed burst, we only need to compare last beat of data
       for (int y=0;y<localbuffer.size();y++) begin
          expected_data = expected_data_array[y];
          read_data     = m_memory.read(item.addr+y);
          actual_data_array[y] = read_data;
          if (expected_data!=read_data) begin
             miscompare_cntr++;
          end
       end

     assert (miscompare_cntr==0) else begin
         write_item_s="";
//        read_item_s="";
         expected_data_s="";
         actual_data_s="";
         localbuffer_s="";

         for (int z=0;z<item.data.size();z++) begin
            $sformat(write_item_s, "%s 0x%2x", write_item_s, item.data[z]);
         end


        for (int z=0;z<expected_data_array.size();z++) begin
          $sformat(expected_data_s, "%s 0x%2x", expected_data_s, expected_data_array[z]);
        end

       for (int z=0;z<actual_data_array.size();z++) begin
         $sformat(actual_data_s, "%s 0x%2x", actual_data_s, actual_data_array[z]);
        end

        for (int z=0;z<localbuffer.size();z++) begin
          $sformat(localbuffer_s, "%s 0x%2x", localbuffer_s, localbuffer[z]);
        end

        msg_s="";
       $sformat(msg_s, "%s %0d miscompares between expected and actual data items.", msg_s, miscompare_cntr );
       $sformat(msg_s, "%s \nExpected:    %s", msg_s, expected_data_s);
       $sformat(msg_s, "%s \nActual:      %s", msg_s, actual_data_s);
       $sformat(msg_s, "%s \nWritten:     %s", msg_s, write_item_s);
       $sformat(msg_s, "%s \nLocalbuffer: %s", msg_s, localbuffer_s);

        `uvm_error("READBACK e_FIXED miscompare", msg_s);
      end




     end else if (item.burst_type == e_INCR) begin
       for (int z=0;z<item.len;z++) begin
          expected_data=item.data[z];
         read_data=m_memory.read(item.addr+z);
          //s=$sformatf("%s 0x%0x", s, read_data);
          assert(expected_data==read_data) else begin
                miscompare_cntr++;
            `uvm_error("e_INCR miscompare",
                       $sformatf("addr:0x%0x expected: 0x%0x   actual:0x%0x",
                                  item.addr+z,
                                  expected_data,
                                  read_data))
          end
       end
     end else if (item.burst_type == e_WRAP) begin

       if (item.addr + item.len < Upper_Wrap_Boundary) begin
         expected_data='h0;
         for (int z=Lower_Wrap_Boundary;z<item.addr;z++) begin
           read_data=m_memory.read(z);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
              `uvm_fatal("e_WRAP miscompare",
                       $sformatf("expected: 0x%0x   actual:0x%0x",
                                 expected_data,
                                 read_data))
            end
         end

         for (int z=0;z<item.len;z++) begin
            expected_data=item.data[z];
           read_data=m_memory.read(item.addr+z);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
               `uvm_fatal("e_WRAP miscompare",
                          $sformatf("expected: 0x%0x   actual:0x%0x",
                                    expected_data,
                                    read_data))
            end
         end

         expected_data='h0;
         for (int z=item.addr+item.len;z<Upper_Wrap_Boundary;z++) begin
           read_data=m_memory.read(z);
           assert(expected_data==read_data) else begin
                miscompare_cntr++;
              `uvm_fatal("e_WRAP miscompare",
                       $sformatf("expected: 0x%0x   actual:0x%0x",
                                 expected_data,
                                 read_data))
            end
         end


       end else begin // data actually wraps.

         // compare beginning of data, which is towards the end of the boundary window
         for (int i=item.addr; i<Upper_Wrap_Boundary; i++) begin
            expected_data=item.data[i-item.addr];
            read_data=m_memory.read(i);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
               `uvm_error("e_WRAP miscompare",
                          $sformatf("expected: 0x%0x   actual:0x%0x",
                                    expected_data,
                                    read_data))
            end
         end

         // at which offset did the wrap occur?  compar that starting at lower_wrap_boundary

         rollover_cnt=item.len-((item.addr+item.len)-Upper_Wrap_Boundary);
         for (int i=rollover_cnt;i<item.len;i++) begin
           expected_data=item.data[i];
           read_data=m_memory.read(Lower_Wrap_Boundary+(i-rollover_cnt));
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
              msg_s="";
              for (int j=Lower_Wrap_Boundary;j<Upper_Wrap_Boundary;j++) begin
                $sformat(msg_s, "%s 0x%2x", msg_s, m_memory.read(j));
              end
               `uvm_fatal("e_WRAP miscompare",
                          $sformatf("Wrap Window contents: [0x%0x - 0x%0x]: %s   expected: 0x%0x   actual:[0x%0x]=0x%0x (rollover_cnt: 0x%0x)",
                                    Lower_Wrap_Boundary,
                                    Upper_Wrap_Boundary-1,
                                    msg_s,
                                    expected_data,
                                    Lower_Wrap_Boundary+(i-rollover_cnt),
                                    read_data,
                                    rollover_cnt))
            end
         end

         // `uvm_warning(this.get_type_name(),
         //              "Not currently verifying eWRAP AXi readback data if data actually wraps.")
       end




     end else begin
                miscompare_cntr++;
        `uvm_fatal(this.get_type_name(), $sformatf("Invalid burst_type: %0d", item.burst_type))
     end


      // compare post-data
      if (postcheck==1) begin
         expected_data='h0;
        for (int i=post_check_start_addr;i<post_check_stop_addr;i++) begin
            read_data=m_memory.read(i);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
               `uvm_error("e_FIXED miscompare",
                          $sformatf("expected: 0x%0x   actual:0x%0x",
                                    expected_data,
                                    read_data))
            end
         end
      end // if postcheck


return (miscompare_cntr == 0);

endfunction : check_memory


// This functionompares thewrite-item withthe correspondingread_item
function bit axi_seq::compare_items (int xfer_cnt);

  bit [2:0] max_burst_size;
  int yy;
  bit [7:0] localbuffer [];
  bit [7:0] read_data;
  bit [7:0] expected_data;
  int idatacntr;
  int miscompare_cntr;
  string write_item_s;
  string read_item_s;
  string expected_data_s;
  string msg_s;
  string localbuffer_s;
  int rollover_cnt;

  bit [7:0] expected_data_array [];


    if (write_item[xfer_cnt].burst_type==e_FIXED) begin

      idatacntr=2**write_item[xfer_cnt].burst_size;

      // compare every nth byte with the same offset byte in last beat.
      // should look like only the last beat got sent repeatedly
      // construct the expected array,, then compare against actual.
      // if miscompare, print original, readback and (calculated) expected.

      miscompare_cntr=0;
      expected_data_array=new[read_item[xfer_cnt].data.size()];

      // brute force, not elegant at all.
      // write to local buffer, then compare that buffer (repeated) with the axi readback


      yy=0;
      localbuffer=new[2**write_item[xfer_cnt].burst_size];
      for (int y=0;y<localbuffer.size();y++) begin
         localbuffer[y]='h0;
      end
      for (int y=0;y<write_item[xfer_cnt].len;y++) begin
        localbuffer[yy++]=write_item[xfer_cnt].data[y];
        if (yy >= 2**write_item[xfer_cnt].burst_size) begin
          yy=0;
        end
      end

      yy=0;
      for (int y=0; y<expected_data_array.size(); y++) begin
        expected_data_array[y]=localbuffer[yy++];
        if (yy >= localbuffer.size()) begin
          yy=0;
        end
      end

      for (int y=0;y<read_item[xfer_cnt].data.size();y++) begin
         expected_data = expected_data_array[y];
         read_data     = read_item[xfer_cnt].data[y];
         if (expected_data!=read_data) begin
            miscompare_cntr++;
         end
      end

      assert (miscompare_cntr==0) else begin
        write_item_s="";
        read_item_s="";
        expected_data_s="";
        localbuffer_s="";

       for (int z=0;z<write_item[xfer_cnt].data.size();z++) begin
          $sformat(write_item_s, "%s 0x%2x", write_item_s, write_item[xfer_cnt].data[z]);
        end

        for (int z=0;z<read_item[xfer_cnt].data.size();z++) begin
          $sformat(read_item_s, "%s 0x%2x", read_item_s, read_item[xfer_cnt].data[z]);
        end

        for (int z=0;z<expected_data_array.size();z++) begin
          $sformat(expected_data_s, "%s 0x%2x", expected_data_s, expected_data_array[z]);
        end

        for (int z=0;z<localbuffer.size();z++) begin
          $sformat(localbuffer_s, "%s 0x%2x", localbuffer_s, localbuffer[z]);
        end


        `uvm_error("AXI READBACK e_FIXED miscompare",
                   $sformatf("%0d miscompares between expected and actual data items.  \nExpected: %s \n  Actual: %s;  \nWritten: %s  \nLocalbuffer: %s", miscompare_cntr, expected_data_s, read_item_s, write_item_s, localbuffer_s ));
      end

      ///   ........................

    end else if (write_item[xfer_cnt].burst_type==e_INCR || write_item[xfer_cnt].burst_type==e_WRAP) begin
      for (int z=0;z<write_item[xfer_cnt].len;z++) begin
         read_data=read_item[xfer_cnt].data[z];
         expected_data=write_item[xfer_cnt].data[z];
         assert(expected_data==read_data) else begin
           miscompare_cntr++;
           `uvm_error("AXI READBACK e_INCR miscompare",
                       $sformatf("expected: 0x%0x   actual:0x%0x",
                                 expected_data,
                                 read_data))
         end
      end
    end else begin
           miscompare_cntr++;
      `uvm_error(this.get_type_name(),
                 $sformatf("Unsupported burst type %0d", write_item[xfer_cnt].burst_type))

    end

return (miscompare_cntr == 0);
endfunction : compare_items
