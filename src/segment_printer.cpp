#include <algorithm>
#include <iterator>
#include <iostream>
#include <map>
#include "graph.h"
#include "store.h"

void segment_printer_body::operator()(printer_input input, printer_node::output_ports_type & op){

    auto &payload = get<0>(input); 
    size_t token  = get<1>(input);
 
    auto &block_data  = get<0>(payload);
    auto &index       = get<1>(payload);
    auto &fw_segments = get<2>(payload);
    auto &rc_segments = get<3>(payload);

    int block_index    = block_data.index;
    size_t block_start = block_data.start;
    uint32_t block_len = block_data.len;
    size_t block_end   = block_start + block_len;

    uint32_t rc_block_start = cfg.seq_len - 1 - block_start - (block_len -1);

    std::string segment_filename;
    std::string cmd;
    
    uint32_t fw_hsps  = fw_segments.size();
    uint32_t rc_hsps  = rc_segments.size();
    uint32_t num_hsps = fw_hsps + rc_hsps;

    size_t r_index;
    size_t seg_r_start;
    size_t q_index;
    size_t seg_q_start;

    if(num_hsps > 0){

        size_t start_chr = std::upper_bound(chr_start.cbegin(), chr_start.cend(), block_start) - chr_start.cbegin() - 1; 
        size_t end_chr = std::upper_bound(chr_start.cbegin(), chr_start.cend(), block_end) - chr_start.cbegin() - 1; 

        uint32_t curr_q_chr_index = start_chr;
        std::string curr_q_chr    = chr_name[start_chr];
        size_t curr_q_chr_start   = chr_start[start_chr]; 
        size_t curr_q_chr_end     = curr_q_chr_start + chr_len[start_chr];

        std::string out_str;
        FILE* segmentFile;

        segment_filename = "tmp"+std::to_string(index)+".block"+std::to_string(block_index)+".segments"; 
        segmentFile = fopen(segment_filename.c_str(), "w");

        if(fw_hsps > 0){

            for (auto e: fw_segments) {
                seg_r_start = block_start + e.ref_start;
                r_index     = std::upper_bound(chr_start.cbegin(), chr_start.cend(), seg_r_start) - chr_start.cbegin() - 1;
                seg_q_start = block_start + e.query_start;

                if(seg_q_start < curr_q_chr_start || seg_q_start >= curr_q_chr_end){
                    q_index = std::upper_bound(chr_start.cbegin(), chr_start.cend(), seg_q_start) - chr_start.cbegin() - 1;
                    curr_q_chr_index = q_index;
                    curr_q_chr       = chr_name[curr_q_chr_index];
                    curr_q_chr_start = chr_start[curr_q_chr_index];
                    curr_q_chr_end   = curr_q_chr_start + chr_len[curr_q_chr_index];
                }

                out_str = chr_name[r_index] + '\t' + std::to_string(seg_r_start-chr_start[r_index]) + '\t' + std::to_string(seg_r_start+e.len+1-chr_start[r_index]) + '\t' + curr_q_chr + '\t' +  std::to_string(seg_q_start-curr_q_chr_start) + '\t' + std::to_string(seg_q_start+e.len+1-curr_q_chr_start) + "\n";
                fprintf(segmentFile, "%s", out_str.c_str());
            }
        }

        curr_q_chr_index    = start_chr;
        curr_q_chr          = chr_name[start_chr];
        curr_q_chr_start    = chr_start[start_chr]; 
        curr_q_chr_end      = curr_q_chr_start + chr_len[start_chr];

        if(rc_hsps > 0){

            for(int r = rc_segments.size()-1; r >= 0; r--){
                auto e =  rc_segments[r];
                seg_r_start = block_start + e.ref_start;
                seg_q_start = cfg.seq_len - 1 - (block_start + e.query_start + e.len);
                r_index = std::upper_bound(chr_start.cbegin(), chr_start.cend(), seg_r_start) - chr_start.cbegin() - 1;

                if(seg_q_start < curr_q_chr_start || seg_q_start >= curr_q_chr_end){
                    q_index = std::upper_bound(chr_start.cbegin(), chr_start.cend(), seg_q_start) - chr_start.cbegin() - 1;
                    curr_q_chr_index = q_index;
                    curr_q_chr = chr_name[curr_q_chr_index];
                    curr_q_chr_start = chr_start[curr_q_chr_index];
                    curr_q_chr_end = curr_q_chr_start + chr_len[curr_q_chr_index];
                }

                out_str = chr_name[r_index] + '\t' + std::to_string(seg_r_start-chr_start[r_index]) + '\t' + std::to_string(seg_r_start+e.len+1-chr_start[r_index]) + '\t' + curr_q_chr + '\t' +  std::to_string(seg_q_start-curr_q_chr_start) + '\t' + std::to_string(seg_q_start+e.len+1-curr_q_chr_start) + "\n";

                fprintf(segmentFile, "%s", out_str.c_str());
            }

        }

        fclose(segmentFile);
    }

    get<0>(op).try_put(token);
};
