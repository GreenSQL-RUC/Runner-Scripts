#importing tsv to csv file for real data 
import re 
import gzip #need this as the file on github is a zip file since it was too large to upload

#reading tsv file in 
with gzip.open("estat_nama_10_a64_p5.tsv.gz", 'rt') as myfile:
    with open("estat_nama_10_a64_p5.csv", 'w') as csv_file:
        for line in myfile:

            #replace every tab with comma
            fileContent = re.sub("\t", ",", line)

            # writing into csv file
            csv_file.write(fileContent)

#printing out 
print("Success")