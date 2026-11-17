// CRLF line ends stay CRLF; a byte order mark stays; a raw string keeps its own bytes
const  RAW=`line one
line two  
   line three`   // after the raw string


fn main(){
  print(RAW,len(RAW))   
}
