			            ||                                                              '||      
			.. .. ..   ...  .. .. ..     ....    ...     ... . ... ..   ....   ... ...   || ..   
			 || || ||   ||   || || ||  .|...|| .|  '|.  || ||   ||' '' '' .||   ||'  ||  ||' ||  
			 || || ||   ||   || || ||  ||      ||   ||   |''    ||     .|' ||   ||    |  ||  ||  
			.|| || ||. .||. .|| || ||.  '|...'  '|..|'  '||||. .||.    '|..'|'  ||...'  .||. ||. 
			                                           .|....'                  ||               
			                                                                   ''''              
## Description
mimeograph is a simple CoffeeScript library to extract text from a PDF, OCRing where necessary.  None of the 
actual PDF operation is performed by the CoffeeScript, everything is farmed out to pdftotext, imagemagick 
and tesseract.

## System Requirements
- poppler-utils (pdftotext)
- tesseract
- ImageMagick