
wget https://github.com/Kitware/CMake/releases/download/v3.16.3/cmake-3.16.3-Linux-x86_64.sh
chmod +x cmake-3.16.3-Linux-x86_64.sh
sudo sh cmake-3.16.3-Linux-x86_64.sh
sudo ln -s cmake-3.16.3-Linux-x86_64/bin/ /usr/local/bin/

wget http://developer.download.nvidia.com/compute/cuda/10.2/Prod/local_installers/cuda_10.2.89_440.33.01_linux.run
sudo sh cuda_10.2.89_440.33.01_linux.run
#add to ~/.bashrc : export PATH="/usr/local/cuda/bin/:$PATH"

wget http://www.bx.psu.edu/~rsharris/lastz/lastz-1.04.03.tar.gz

Download bond which Yatish sent via Gmail